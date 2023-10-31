// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/token/ERC20/SafeERC20.sol";


import "./PanToken.sol";
import "./PanBakery.sol";

// import "@nomiclabs/buidler/console.sol";

interface IMigratorBaker {
    // Perform LP token migration from legacy CreampanSwap to PanSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to CreampanSwap LP tokens.
    // PanSwap must mint EXACTLY the same amount of PanSwap LP tokens or
    // else something bad will happen. Traditional CreampanSwap does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// MasterBaker is the master of Pan. He can make Pan and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once PAN is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterBaker is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    /// using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of PANs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accPanPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accPanPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. PANs to distribute per block.
        uint256 lastRewardBlock; // Last block number that PANs distribution occurs.
        uint256 accPanPerShare; // Accumulated PANs per share, times 1e12. See below.
    }

    // The PAN TOKEN!
    PanToken public pan;
    // The BAKERY TOKEN!
    PanBakery public bakery;
    // Team address.
    address payable public teamaddr;
    // Maint address.
    address public maintaddr;
    // Dev address.
    address public devaddr;

    // PAN tokens created per block.
    uint256 public panPerBlock;
    // Bonus muliplier for early pan makers.
    uint256 public BONUS_MULTIPLIER = 1;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorBaker public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when PAN mining starts.
    uint256 public startBlock;
    // The ration of single-sided PAN pool against totalAllocPoint
    uint256 public panStakingRatio = 25;
    // The maximum era for block reward having
    uint256 public limitEra;
    // Record current era
    uint256 public currentEra;


// Multisig and timelock
    address [] public signers;
    mapping(address => bool) public isSigner;
    mapping(uint256 => mapping(address => bool)) public isSetConfirmed;

    uint256 public numConfirmationsRequired; // total confirmations needed
    uint256 public setConfirmations;         // confirmations for current set
    //
    uint256 public submitted;          // total submitted set
    bool    public requestSet;         // submit set flag
    uint256 public submitSetTimestamp; // submit set time
    //
    address public setter;             // assigned one-time setter
    address public submittedSetter;    // submitted setter for confirmation
    uint256 public setUnlockTime;      // Unlocktime for set after confirmation
    //
//


    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UpdatedPANStakingRatio(uint256 newRatio);
    event UpdatedPANPerBlock(uint256 newPanPerBlock);

    constructor(
        PanToken _pan,
        PanBakery _bakery,
        address payable _teamaddr,
        address _maintaddr,        
        address _devaddr,
        uint256 _panPerBlock,
        uint256 _startBlock,
        address [] memory _signers,
        uint256 _numConfirmationsRequired
    ) public {
        require(_signers.length           >= 5, "Number of signers has to be larger than or equal to five");
        require(_numConfirmationsRequired >= 3, "Number of required confirmations has to be larger than or equal to three");

        pan = _pan;
        bakery = _bakery;
        teamaddr = _teamaddr;
        maintaddr = _maintaddr;
        devaddr = _devaddr;
        panPerBlock = _panPerBlock;
        startBlock = _startBlock;
        limitEra = 7;
        currentEra = 0;

        // staking pool
        poolInfo.push(PoolInfo({lpToken: _pan, allocPoint: 1000, lastRewardBlock: startBlock, accPanPerShare: 0}));

        totalAllocPoint = 1000;

        //Multisig
        numConfirmationsRequired = _numConfirmationsRequired;

        for (uint256 i=0; i < _signers.length; i++) {
            address signer = _signers[i];
    
            require(signer           != address(0), "signer cannot be zero");
            require(isSigner[signer] == false     , "signer should be unique");

            isSigner[signer] = true;
            signers.push(signer);
        }
        //
    }

    receive() external payable {
    }

    function updateMultiplier(uint256 multiplierNumber) public {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        BONUS_MULTIPLIER = multiplierNumber;

        _cleanset();                                                     //Clean setter
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({lpToken: _lpToken, allocPoint: _allocPoint, lastRewardBlock: lastRewardBlock, accPanPerShare: 0})
        );
        updateStakingPool();

        _cleanset();                                                     //Clean setter
    }

    // Update the given pool's PAN allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }

        _cleanset();                                                     //Clean setter
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.mul(panStakingRatio).div(100 - panStakingRatio);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorBaker _migrator) public {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        migrator = _migrator;

        _cleanset();                                                     //Clean setter
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending PANs on frontend.
    function pendingPan(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPanPerShare = pool.accPanPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 panReward = multiplier.mul(panPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accPanPerShare = accPanPerShare.add(panReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accPanPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 panReward = multiplier.mul(panPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        pan.mint(teamaddr,  panReward.mul(18).div(100));
        pan.mint(maintaddr, panReward.mul(13).div(100));
        pan.mint(devaddr,   panReward.mul(18).div(100));
        pan.mint(address(bakery), panReward.mul(51).div(100));
        pool.accPanPerShare = pool.accPanPerShare.add(panReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterBaker for PAN allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        require(_pid != 0, "deposit PAN by staking");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accPanPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safePanTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPanPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterBaker.
    function withdraw(uint256 _pid, uint256 _amount) public {
        require(_pid != 0, "withdraw PAN by unstaking");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accPanPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safePanTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPanPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Stake PAN tokens to MasterBaker
    function enterStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accPanPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safePanTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPanPerShare).div(1e12);

        bakery.mint(msg.sender, _amount);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw PAN tokens from STAKING.
    function leaveStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accPanPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safePanTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPanPerShare).div(1e12);

        bakery.burn(msg.sender, _amount);
        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe pan transfer function, just in case if rounding error causes pool to not have enough PANs.
    function safePanTransfer(address _to, uint256 _amount) internal {
        bakery.safePanTransfer(_to, _amount);
    }

    // Update team address by the previous team.
    function team(address payable _teamaddr) public {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock        
        
        teamaddr = _teamaddr;

        _cleanset();                                                     //Clean setter
    }

    // Update maint address by the previous maint.
    function maint(address _maintaddr) public {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock        

        maintaddr = _maintaddr;

        _cleanset();                                                     //Clean setter
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock        

        devaddr = _devaddr;

        _cleanset();                                                     //Clean setter
    }

    function updateStakingRatio(uint256 _ratio) public {
        require(_ratio <= 50, "updateStakingRatio: must be less than 50%");

        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        massUpdatePools();
        panStakingRatio = _ratio;
        updateStakingPool();

        _cleanset();                                                     //Clean setter

        emit UpdatedPANStakingRatio(_ratio);
    }

    function updatePanPerBlock() public {
        uint256 panInit     = pan.initBlock();
        require(block.number > panInit, "block number must larger than PAN initial block");
        uint256 totalBlocks = block.number - panInit;
        uint256 whatEra = totalBlocks.div(365).div(pan.blockPerDay());

        if (whatEra > currentEra) {
            panPerBlock = (whatEra > limitEra) ? panPerBlock : panPerBlock.div(2);
            currentEra  = (whatEra > limitEra) ? currentEra  : currentEra + 1;
        }

        emit UpdatedPANPerBlock(panPerBlock);
    }

    function setLimitEra(uint256 _limitEra) public {
        require(_limitEra>0,   "the Era limit should larger than zero");
        require(_limitEra<=50, "the Era limit should less than fifty");

        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        limitEra = _limitEra;

        _cleanset();                                                     //Clean setter
    }

    function sendRewards() public {
        require(address(this).balance > 0, "No rewards to send");

        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        teamaddr.transfer(address(this).balance);

        _cleanset();                                                     //Clean setter        
    }

// Multisig
    function _cleanset() internal {
        requestSet       = false;
        setter           = address(0);
        setConfirmations = 0;
        submitted += 1;
    }

    function dropSet() external {
        require(requestSet == true, "no submission to drop");
        require(block.timestamp > (submitSetTimestamp + 1 days), "submission is still in confirmation");
        require(setConfirmations < numConfirmationsRequired, "The set is confirmed");
        require(isSigner[msg.sender] == true, "only signer can drop set");

        requestSet       = false;
        submittedSetter  = address(0);
        setConfirmations = 0;
        submitted += 1;
    }

    function submitSet(address _setter) external {
        require(_setter != address(0), "Error: zero address cannot be setter");
        require(requestSet == false, "submission to confirm");
        require(isSigner[msg.sender] == true, "only signer can submit set");

        requestSet = true;
        submitSetTimestamp = block.timestamp;
        submittedSetter = _setter;
    }

    function confirmSet() external {
        require(requestSet == true, "no submission to confirm");
        require(isSigner[msg.sender] == true, "only signer can confirm the set");
        require(isSetConfirmed[submitted][msg.sender] == false, "the signer has confirmed");

        isSetConfirmed[submitted][msg.sender] = true;
        setConfirmations += 1;
    }

    function releaseSetter() external {
        require(setter == address(0), "setter has been released");
        require(isSigner[msg.sender] == true, "only signer can release the setter");
        require(setConfirmations >= numConfirmationsRequired, "Confirmations are not enough");

        setter = submittedSetter;
        setUnlockTime = block.timestamp + 10 minutes;  //Time lock
    }
//

}
