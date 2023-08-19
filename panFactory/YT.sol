// SPDX-License-Identifier: MIT

pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.4.0/contracts/utils/Address.sol";

import './interfaces/IWCRO.sol';

contract ytCRO is ERC20("YT CRO Token", "ytCRO"), Ownable, ReentrancyGuard {
    using Address for address payable;

    IWCRO public WCRO;

    struct UserInfo {
        uint256 lastRewards;
        uint256 pendingRewards;
    }

    address public claimTo;
    address public claimToSetter;

    uint256 public accTokenPerShare;

    uint256 public totalDistibuted;
    uint256 public totalReleased;

    uint256 public constant ACC_PRECISION = 1e12;

    mapping(address => UserInfo) public userInfo;

    event Claim(address indexed user, uint256 amount);
    event ClaimToWCRO(address indexed user, uint256 amount);

    constructor(IWCRO _wcro, address _claimToSetter) {
        require(_claimToSetter != address(0), "claimToSetter address cannot be zero");
        
        WCRO = _wcro;
        claimToSetter = _claimToSetter;
    }

    function depositRewards() public payable {
        WCRO.deposit{value: msg.value}();
        _updateInfo();
    }

    receive() external payable {
        assert(msg.sender == address(WCRO)); // only accept CRO via fallback from the WCRO contract
    }

    function getPendingRewards(address addr) external view returns (uint256) {
        require(addr != address(0), "Invalid user address");
        UserInfo storage user = userInfo[addr];
        uint256 calTokenPerShare = accTokenPerShare;
        uint256 balance = balanceOf(addr);
        uint256 totalSupply = totalSupply();

        if (balance!=0) {
            uint256 DistributableRewards = getTotalDistributableRewards();
            calTokenPerShare += DistributableRewards * ACC_PRECISION / totalSupply;
        }
        return accumulaitveRewards(balance, calTokenPerShare) - user.lastRewards + user.pendingRewards;
    }

    function getTotalDistributableRewards() public view returns (uint256) {
        return WCRO.balanceOf(address(this)) + totalReleased - totalDistibuted;
    }

    function accumulaitveRewards(uint256 amount, uint256 _accTokenPerShare) internal pure returns (uint256) {
        return (amount * _accTokenPerShare) / (ACC_PRECISION);
    }

    function setClaimTo(address _claimTo) external {
        require(msg.sender == claimToSetter, 'Creampan: FORBIDDEN');
        require(_claimTo != address(0), "claimTo address cannot be zero");

        claimTo = _claimTo;
    }

    function setClaimToSetter(address _claimToSetter) external {
        require(msg.sender == claimToSetter, 'Creampan: FORBIDDEN');
        require(_claimToSetter != address(0), "claimToSetter address cannot be zero");

        claimToSetter = _claimToSetter;
    }

    function _updateInfo() internal {
        uint256 DistributableRewards = getTotalDistributableRewards();
        uint256 totalSupply = totalSupply();

        if (totalSupply==0) {
            return;
        }

        accTokenPerShare += DistributableRewards * ACC_PRECISION / totalSupply;
        totalDistibuted += DistributableRewards;
    }

    function _updateUserPendingRwards(address addr) internal {
        UserInfo storage user = userInfo[addr];
        uint256 balance = balanceOf(addr);
        if (balance == 0) {
            return;
        }
        user.pendingRewards += accumulaitveRewards(balance, accTokenPerShare) - user.lastRewards;
    }

    function claim() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        address payable recipient = payable(msg.sender);
        _updateInfo();
        _updateUserPendingRwards(msg.sender);
        uint256 balance = balanceOf(msg.sender);
        uint256 rewards = user.pendingRewards;
        require(rewards != 0, "No rewards to claim");

        if (user.pendingRewards>0) {
            totalReleased += user.pendingRewards;
            user.pendingRewards -= rewards;
        }
        user.lastRewards = accumulaitveRewards(balance, accTokenPerShare);
        WCRO.withdraw(rewards);
        recipient.sendValue(rewards);
        emit Claim(msg.sender, rewards);
    }

    function claimToWCRO() external {
        UserInfo storage user = userInfo[msg.sender];
        _updateInfo();
        _updateUserPendingRwards(msg.sender);
        uint256 balance = balanceOf(msg.sender);
        uint256 rewards = user.pendingRewards;
        require(rewards != 0, "No rewards to claim");

        if (user.pendingRewards>0) {
            totalReleased += user.pendingRewards;
            user.pendingRewards -= rewards;
        }
        user.lastRewards = accumulaitveRewards(balance, accTokenPerShare);
        assert(WCRO.transfer(msg.sender, rewards));
        emit ClaimToWCRO(msg.sender, rewards);
    }

    function claim(address payable addr) external nonReentrant {
        require(msg.sender == claimTo, 'Creampan: FORBIDDEN');
        require(addr != address(0), "addr address cannot be zero");

        UserInfo storage user = userInfo[addr];
        _updateInfo();
        _updateUserPendingRwards(addr);
        uint256 balance = balanceOf(addr);
        uint256 rewards = user.pendingRewards;
        require(rewards != 0, "No rewards to claim");

        if (user.pendingRewards>0) {
            totalReleased += user.pendingRewards;
            user.pendingRewards -= rewards;
        }
        user.lastRewards = accumulaitveRewards(balance, accTokenPerShare);
        WCRO.withdraw(rewards);
        addr.sendValue(rewards);
        emit Claim(addr, rewards);
    }

    function claimToWCRO(address addr) external {
        require(msg.sender == claimTo, 'Creampan: FORBIDDEN');
        require(addr != address(0), "addr address cannot be zero");

        UserInfo storage user = userInfo[addr];
        _updateInfo();
        _updateUserPendingRwards(addr);
        uint256 balance = balanceOf(addr);
        uint256 rewards = user.pendingRewards;
        require(rewards != 0, "No rewards to claim");

        if (user.pendingRewards>0) {
            totalReleased += user.pendingRewards;
            user.pendingRewards -= rewards;
        }
        user.lastRewards = accumulaitveRewards(balance, accTokenPerShare);
        assert(WCRO.transfer(addr, rewards));
        emit ClaimToWCRO(addr, rewards);
    }

    function mint(address _to, uint256 _amount) public onlyOwner {
        //_beforeTokenTransfer
        _mint(_to, _amount);
        //_afterTokenTransfer
    }

    function burn(address _from, uint256 _amount) public onlyOwner {
        //_beforeTokenTransfer
        _burn(_from, _amount);
        //_afterTokenTransfer
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        _updateInfo();
        if (from != address(0)) { 
            _updateUserPendingRwards(from);
        }
        if (to   != address(0)) {
            _updateUserPendingRwards(to);         
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from != address(0)) {
            UserInfo storage user_from = userInfo[from];
            uint256 balance_from = balanceOf(from);
            user_from.lastRewards = accumulaitveRewards(balance_from, accTokenPerShare);
        }
        if (to   != address(0)) {
            UserInfo storage user_to = userInfo[to];
            uint256 balance_to = balanceOf(to);
            user_to.lastRewards = accumulaitveRewards(balance_to, accTokenPerShare);            
        }
    }

}
