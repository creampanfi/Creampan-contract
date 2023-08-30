// SPDX-License-Identifier: MIT

pragma solidity 0.8.0;

import "./interfaces/IPanToken.sol";
import "./interfaces/ICROBridge.sol";
import "./interfaces/IPT.sol";
import "./interfaces/IYT.sol";
import "./interfaces/IWCRO.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.4.0/contracts/utils/Address.sol";

contract Factory is Ownable, Pausable, ReentrancyGuard {
    using Address for address payable;

    IPanToken public PanToken;
    IWCRO public WCRO;
    ICroBridge public CROBridge;
    IPT public ptToken;
    IYT public ytToken;

    string public delegationAddress;

    address public feeTo;

    uint256 public delegationRatio;
    uint256 public targetRatio;

    uint256 public depositedAmount;
    uint256 public withdrawnAmount;
    uint256 public delegationAmount;
    uint256 public undelegationAmount;

    uint256 public feeBase;
    uint256 public feeKink;
    uint256 public multiple;
    uint256 public jumpMultiple;
    uint256 public feeAmount;
    
    bool    public eatPANOn;
    uint256 public eatPANAmount;

    uint256 public holdLevelThreshold;
    
// Multisig and timelock
    address [] public signers;
    mapping(address => bool) public isSigner;
    mapping(uint256 => mapping(address => bool)) public isSetConfirmed;
    mapping(uint256 => mapping(address => bool)) public isUpdateConfirmed;

    uint256 public numConfirmationsRequired; // total confirmations needed
    uint256 public setConfirmations;         // confirmations for current set
    uint256 public updateConfirmations;      // confirmations for current update
    //
    uint256 public submitted;          // total submitted set
    bool    public requestSet;         // submit set flag
    uint256 public submitSetTimestamp; // submit set time
    //
    address public setter;             // assigned one-time setter
    address public submittedSetter;    // submitted setter for confirmation
    uint256 public setUnlockTime;      // Unlocktime for set after confirmation
    //
    uint256 public updated;               // total submitted update
    bool    public requestUpdate;         // submit update flag
    uint256 public submitUpdateTimestamp; // submit update time
    //
    address public updater;               // assigned one-time updater
    address public submittedUpdater;      // submitted updater for confirmation
    //
//

    event Mint(address indexed user, uint256 amount);
    event MintFromWCRO(address indexed user, uint256 amount);
    event Burn(address indexed user, uint256 amount);
    event BurnToWCRO(address indexed user, uint256 amount);
    event SetToken(address CROBridge, address indexed ptToken, address indexed ytToken, address WCRO);
    event SetEatPAN(bool _eatPANOn, uint256 _eatPANAmount);
    event SetHoldLevelThreshold(uint256 holdLevelThreshold);
    event SetTargetRatio(uint256 targetRatio);  
    event SetFeeRate(uint256 feeBase, uint256 feeKink, uint256 multiple, uint256 jumpMultiple);
    event SetDelegateAddress(string indexed delegationAddress);
    event UpdateDelegate(uint256 delegationAmount);
    event UpdateUndelegation(uint256 undelegationAmount);
    event Pause();
    event Unpause();

    constructor(string memory _delegationAddress,
                IPanToken _panToken,
                ICroBridge _croBridge,
                IPT _ptToken,
                IYT _ytToken,
                IWCRO _wcro,
                uint256 _targetRatio,
                address [] memory _signers,
                uint256 _numConfirmationsRequired ) {
        require(_signers.length           >= 5, "Number of signers has to be larger than or equal to five");
        require(_numConfirmationsRequired >= 3, "Number of required confirmations has to be larger than or equal to three");

        delegationAddress  = _delegationAddress;
        PanToken           = _panToken;
        CROBridge          = _croBridge;
        ptToken            = _ptToken;
        ytToken            = _ytToken;
        WCRO               = _wcro;
        targetRatio        = _targetRatio;
        eatPANOn           = false;
        eatPANAmount       = 100 * 1e18;
        holdLevelThreshold = 2500 * 1e18;
        feeBase            = 5000;
        feeKink            = 650000;
        multiple           = 25000;
        jumpMultiple       = 500000;

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

    function depositFunds() public payable {
        WCRO.deposit{value: msg.value}();
        _updateUndelegation(msg.value);
    }

    receive() external payable {
        assert(msg.sender == address(WCRO)); // only accept CRO via fallback from the WCRO contract
    }

    function getDelegationRatio() public view returns (uint256) {
        return delegationRatio;
    }

    function getTargetRatio() public view returns (uint256) {
        return targetRatio;
    }

    function getHoldDiscount(address addr) public view returns (uint256) {
        uint256 panBalance = PanToken.balanceOf(addr);
        if      (panBalance >= (100*holdLevelThreshold))
            return 55;
        else if (panBalance >= (10*holdLevelThreshold))
            return 75;
        else if (panBalance >=     holdLevelThreshold)
            return 90;
        else
            return 100;
    }

    function getCurrentFee() public view returns (uint256) {
        require(targetRatio < 1e6, "TargetRatio should be less than 1e6");

        uint256 ReserveRatio = (1e6 - delegationRatio)*1e6 / (1e6 - targetRatio);
        uint256 utilizationRate;
        if (ReserveRatio<1e6) {
            utilizationRate = (1e6 - ReserveRatio);
        }
        else {
            utilizationRate = 0;
        }

        if (utilizationRate <= feeKink) {
            return (utilizationRate*multiple/1e6 + feeBase);
        }
        else {
            uint256 normalRate = feeKink*multiple/1e6 + feeBase;
            uint256 excessUtil = utilizationRate - feeKink;
            return (excessUtil*jumpMultiple/1e6 + normalRate);
        }
    }

    function setToken(IPanToken _panToken, ICroBridge _croBridge, IPT _ptToken, IYT _ytToken, IWCRO _wcro) external {
        require(address(_panToken)  != address(0), "Invalid panToken Address");
        require(address(_croBridge) != address(0), "Invalid croBridge Address");
        require(address(_ptToken)   != address(0), "Invalid ptToken Address");
        require(address(_ytToken)   != address(0), "Invalid ytToken Address");
        require(address(_wcro)      != address(0), "Invalid WCRO Address");

        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        PanToken = _panToken;
        CROBridge = _croBridge;
        ptToken = _ptToken;
        ytToken = _ytToken;
        WCRO = _wcro;

        _cleanset();                                                     //Clean setter

        emit SetToken(address(CROBridge), address(ptToken), address(ytToken), address(WCRO));
    }

    function setTargetRatio(uint256 _ratio) external {
        require(_ratio >    0, "Ratio should be larger than 0");
        require(_ratio <  1e6, "Ratio should be less than 1e6");

        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        targetRatio = _ratio;

        _cleanset();                                                     //Clean setter

        emit SetTargetRatio(targetRatio);
    }

    function setDelegateAddress(string memory _delegationAddress) external {
        require(updater != address(0), "No updater is assigned");           //Multisig
        require(msg.sender == updater, "Only updater can set parameters");  //Multisig

        delegationAddress = _delegationAddress;

        _cleanupdate();                                                     //Clean updater

        emit SetDelegateAddress(delegationAddress);
    }

    function setEatPAN(bool _eatPANOn, uint256 _eatPANAmount) external {
        require(_eatPANAmount < 1e24, "Amount should be less than 1e6 PAN");

        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        eatPANOn = _eatPANOn;
        eatPANAmount = _eatPANAmount;

        _cleanset();                                                     //Clean setter

        emit SetEatPAN(eatPANOn, eatPANAmount);
    }

    function setHoldLevelThreshold(uint256 _holdLevelThreshold) external {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        holdLevelThreshold = _holdLevelThreshold;

        _cleanset();                                                     //Clean setter

        emit SetHoldLevelThreshold(holdLevelThreshold);
    }

    function setFeeRate(uint256 _feeBase, uint256 _feeKink, uint256 _multiple, uint256 _jumpMultiple) external {
        require(_feeBase      <= 1e6, "FeeBase should be less than 1e6");
        require(_feeKink      <= 1e6, "FeeKink should be less than 1e6");
        require(_multiple     <= 1e6, "Multiple should be less than 1e6");
        require(_jumpMultiple <= 1e6, "jumpMultiple should be less than 1e6");

        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        feeBase = _feeBase;
        feeKink = _feeKink;
        multiple = _multiple;
        jumpMultiple = _jumpMultiple;

        _cleanset();                                                     //Clean setter

        emit SetFeeRate(feeBase, feeKink, multiple, jumpMultiple);
    }

    function setFeeTo(address _feeTo) external {
        require(_feeTo != address(0), "feeTo address cannot be zero");

        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        feeTo = _feeTo;

        _cleanset();                                                     //Clean setter        
    }

    function claimFee() external whenNotPaused {
        require(feeTo != address(0), "Error: claim fee to the zero address");

        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        uint256 amount = feeAmount;
        withdrawnAmount += amount;
        feeAmount = 0;

        _cleanset();                                                     //Clean setter

        assert(WCRO.transfer(feeTo, amount));
    }

    function updateDelegate(uint256 amount) external {
        require(amount                            <  (depositedAmount-withdrawnAmount), "Delegation should be less than totalDeposit");
        require((depositedAmount-withdrawnAmount) >= (delegationAmount+amount)        , "depositedAmount should be larger than delegationAmount");

        require(updater != address(0), "No updater is assigned");           //Multisig
        require(msg.sender == updater, "Only updater can set parameters");  //Multisig

        delegationAmount += amount;
        _updateDelegationRatio();

        _cleanupdate();                                                     //Clean updater

        emit UpdateDelegate(delegationAmount);
    }

    function _updateUndelegation(uint256 amount) internal {
        require(amount           <  (depositedAmount-withdrawnAmount), "Undelegation should be less than totalDeposit");
        require(delegationAmount >= (undelegationAmount+amount)      , "delegationAmount should be larger than undelegationAmount");
        undelegationAmount += amount;

        _updateDelegationRatio();
        emit UpdateUndelegation(undelegationAmount);
    }

    function _updateDelegationRatio() internal {
        require(depositedAmount > 0               , "depositedAmount should be large than 0");    
        require(depositedAmount >= withdrawnAmount, "depositedAmount should be large than or equal to withdrawnAmount");

        if ((depositedAmount-withdrawnAmount)>0) {
            delegationRatio = ((delegationAmount-undelegationAmount) * 1e6) / (depositedAmount-withdrawnAmount);
        }
        else {
            delegationRatio = 0;
        }
    }

    function mint(address _to) public payable whenNotPaused {
        depositedAmount += msg.value;
        _updateDelegationRatio();

        uint256 toWCROAmount = msg.value;

        if (targetRatio>delegationRatio) {
            uint256 targetAmount = (targetRatio - delegationRatio) * (depositedAmount-withdrawnAmount) / 1e6;
            if (targetAmount > msg.value) {
                CROBridge.send_cro_to_crypto_org{value:  msg.value}(delegationAddress);
                toWCROAmount = 0;
            }
            else {
                CROBridge.send_cro_to_crypto_org{value: targetAmount}(delegationAddress);
                toWCROAmount = msg.value - targetAmount;
            }
        }
        WCRO.deposit{value: toWCROAmount}();
        ptToken.mint(_to, msg.value);
        ytToken.mint(_to, msg.value);
        emit Mint(_to, msg.value);
    }

    function mintFromWCRO(address _to, uint256 amount) public whenNotPaused {
        assert(WCRO.transferFrom(msg.sender, address(this), amount));
        depositedAmount += amount;

        _updateDelegationRatio();

        if (targetRatio>delegationRatio) {
            uint256 targetAmount = (targetRatio - delegationRatio) * (depositedAmount-withdrawnAmount) / 1e6;
            if (targetAmount > amount) {
                WCRO.withdraw(amount);
                CROBridge.send_cro_to_crypto_org{value:  amount}(delegationAddress);
            }
            else {
                WCRO.withdraw(targetAmount);
                CROBridge.send_cro_to_crypto_org{value: targetAmount}(delegationAddress);
            }
        }
        ptToken.mint(_to, amount);
        ytToken.mint(_to, amount);
        emit Mint(_to, amount);
    }

    function burn(uint256 amount) public whenNotPaused nonReentrant {
        address payable owner = payable(msg.sender);
        require(owner != address(0), "Error: burn from the zero address");

        uint256 panBalance = PanToken.balanceOf(owner);
        uint256 ptBalance = ptToken.balanceOf(owner);
        uint256 ytBalance = ytToken.balanceOf(owner);
        require(ptBalance >= amount, "ptToken: burn amount exceeds balance");
        require(ytBalance >= amount, "ytToken: burn amount exceeds balance");
        require(WCRO.balanceOf(address(this)) >= amount, "Burn amount exceeds contract balance");
        
        uint256 holdDiscount = getHoldDiscount(owner);
        uint256 feeRate = getCurrentFee();
        uint256 fee;
        fee = ( amount*feeRate*holdDiscount/100 ) / 1e6;
        feeAmount += fee;

        uint256 transAmount = amount - fee;

        withdrawnAmount += transAmount;
        _updateDelegationRatio();

        if (eatPANOn) {
            uint256 burnAmount = eatPANAmount*holdDiscount/100;
            require(panBalance >= burnAmount, "PAN Token: burn amount exceeds balance");
            PanToken.burn(burnAmount);
        }

        WCRO.withdraw(transAmount);
        ptToken.burn(owner, amount);
        ytToken.burn(owner, amount);

        owner.sendValue(transAmount);
        emit Burn(owner, transAmount);
    }

    function burnToWCRO(uint256 amount) public whenNotPaused {
        address owner = msg.sender;
        require(owner != address(0), "Error: burn from the zero address");

        uint256 panBalance = PanToken.balanceOf(owner);
        uint256 ptBalance = ptToken.balanceOf(owner);
        uint256 ytBalance = ytToken.balanceOf(owner);
        require(ptBalance >= amount, "ptToken: burn amount exceeds balance");
        require(ytBalance >= amount, "ytToken: burn amount exceeds balance");
        require(WCRO.balanceOf(address(this)) >= amount, "Burn amount exceeds contract balance");
        
        uint256 holdDiscount = getHoldDiscount(owner);
        uint256 feeRate = getCurrentFee();
        uint256 fee;
        fee = ( amount*feeRate*holdDiscount/100 ) / 1e6;
        feeAmount += fee;

        uint256 transAmount = amount - fee;

        withdrawnAmount += transAmount;
        _updateDelegationRatio();

        if (eatPANOn) {
            uint256 burnAmount = eatPANAmount*holdDiscount/100;
            require(panBalance >= burnAmount, "PAN Token: burn amount exceeds balance");
            PanToken.burn(burnAmount);
        }

        ptToken.burn(owner, amount);
        ytToken.burn(owner, amount);

        assert(WCRO.transfer(owner, transAmount));
        emit BurnToWCRO(owner, transAmount);
    }

    function pause() external whenNotPaused {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        _pause();

        _cleanset();                                                     //Clean setter

        emit Pause();
    }

    function unpause() external whenPaused {
        require(setter != address(0), "No setter is assigned");          //Multisig
        require(msg.sender == setter, "Only setter can set parameters"); //Multisig
        require(block.timestamp > setUnlockTime, "Not ready to set");    //Timelock

        _unpause();

        _cleanset();                                                     //Clean setter

        emit Unpause();
    }

// Multisig
    function _cleanset() internal {
        requestSet       = false;
        setter           = address(0);
        setConfirmations = 0;
        submitted += 1;
    }

    function _cleanupdate() internal {
        requestUpdate       = false;
        updater             = address(0);
        updateConfirmations = 0;
        updated += 1;
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

    function dropUpdate() external {
        require(requestUpdate == true, "no submission to drop");
        require(block.timestamp > (submitUpdateTimestamp + 1 days), "submission is still in confirmation");
        require(updateConfirmations < numConfirmationsRequired, "The update is confirmed");
        require(isSigner[msg.sender] == true, "only signer can drop update");

        requestUpdate       = false;
        submittedUpdater    = address(0);
        updateConfirmations = 0;
        updated += 1;
    }

    function submitSet(address _setter) external {
        require(_setter != address(0), "Error: zero address cannot be setter");
        require(requestSet == false, "submission to confirm");
        require(isSigner[msg.sender] == true, "only signer can submit set");

        requestSet = true;
        submitSetTimestamp = block.timestamp;
        submittedSetter = _setter;
    }

    function submitUpdate(address _updater) external {
        require(_updater != address(0), "Error: zero address cannot be updater");
        require(requestUpdate == false, "submission to confirm");
        require(isSigner[msg.sender] == true, "only signer can submit update");

        requestUpdate = true;
        submitUpdateTimestamp = block.timestamp;
        submittedUpdater = _updater;
    }

    function confirmSet() external {
        require(requestSet == true, "no submission to confirm");
        require(isSigner[msg.sender] == true, "only signer can confirm the set");
        require(isSetConfirmed[submitted][msg.sender] == false, "the signer has confirmed");

        isSetConfirmed[submitted][msg.sender] = true;
        setConfirmations += 1;
    }

    function confirmUpdate() external {
        require(requestUpdate == true, "no submission to confirm");
        require(isSigner[msg.sender] == true, "only signer can confirm the update");
        require(isUpdateConfirmed[updated][msg.sender] == false, "the signer has confirmed");

        isUpdateConfirmed[submitted][msg.sender] = true;
        updateConfirmations += 1;
    }

    function releaseSetter() external {
        require(setter == address(0), "setter has been released");
        require(isSigner[msg.sender] == true, "only signer can release the setter");
        require(setConfirmations >= numConfirmationsRequired, "Confirmations are not enough");

        setter = submittedSetter;
        setUnlockTime = block.timestamp + 2 days;  //Time lock
    }

    function releaseUpdater() external {
        require(updater == address(0), "updater has been released");
        require(isSigner[msg.sender] == true, "only signer can release the updater");
        require(updateConfirmations >= numConfirmationsRequired, "Confirmations are not enough");

        updater = submittedUpdater;
    }
//


}
