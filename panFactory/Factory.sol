// SPDX-License-Identifier: MIT

pragma solidity 0.8.0;

import "./interfaces/IPanToken.sol";
import "./interfaces/ICROBridge.sol";
import "./interfaces/IPT.sol";
import "./interfaces/IYT.sol";
import "./interfaces/IWCRO.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract Factory is Ownable, Pausable {

    IPanToken public PanToken;
    IWCRO public WCRO;
    ICroBridge public CROBridge;
    IPT public ptToken;
    IYT public ytToken;

    string public delegationAddress;

    address public feeTo;
    address public feeToSetter;

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
                address _feeToSetter           ) {
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
        feeToSetter        = _feeToSetter;
        feeBase            = 5000;
        feeKink            = 650000;
        multiple           = 25000;
        jumpMultiple       = 500000;

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

    function setToken(IPanToken _panToken, ICroBridge _croBridge, IPT _ptToken, IYT _ytToken, IWCRO _wcro) external onlyOwner {
        require(address(_panToken)  != address(0), "Invalid panToken Address");
        require(address(_croBridge) != address(0), "Invalid croBridge Address");
        require(address(_ptToken)   != address(0), "Invalid ptToken Address");
        require(address(_ytToken)   != address(0), "Invalid ytToken Address");
        require(address(_wcro)      != address(0), "Invalid WCRO Address");

        PanToken = _panToken;
        CROBridge = _croBridge;
        ptToken = _ptToken;
        ytToken = _ytToken;
        WCRO = _wcro;
        emit SetToken(address(CROBridge), address(ptToken), address(ytToken), address(WCRO));
    }

    function setTargetRatio(uint256 _ratio) external onlyOwner {
        require(_ratio >    0, "Ratio should be larger than 0");
        require(_ratio <  1e6, "Ratio should be less than 1e6");
        targetRatio = _ratio;
        emit SetTargetRatio(targetRatio);
    }

    function setDelegateAddress(string memory _delegationAddress) external onlyOwner {
        delegationAddress = _delegationAddress;
        emit SetDelegateAddress(delegationAddress);
    }

    function setEatPAN(bool _eatPANOn, uint256 _eatPANAmount) external onlyOwner {
        eatPANOn = _eatPANOn;
        eatPANAmount = _eatPANAmount;
        emit SetEatPAN(eatPANOn, eatPANAmount);
    }

    function setHoldLevelThreshold(uint256 _holdLevelThreshold) external onlyOwner {
        holdLevelThreshold = _holdLevelThreshold;
        emit SetHoldLevelThreshold(holdLevelThreshold);
    }

    function setFeeRate(uint256 _feeBase, uint256 _feeKink, uint256 _multiple, uint256 _jumpMultiple) external onlyOwner {
        require(_feeBase <= 1e6, "Ratio should be less than 1e6");
        require(_feeKink <= 1e6, "Ratio should be less than 1e6");

        feeBase = _feeBase;
        feeKink = _feeKink;
        multiple = _multiple;
        jumpMultiple = _jumpMultiple;
        emit SetFeeRate(feeBase, feeKink, multiple, jumpMultiple);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'Creampan: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'Creampan: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    function claimFee() external onlyOwner whenNotPaused {
        require(feeTo != address(0), "Error: claim fee to the zero address");
        uint256 amount = feeAmount;
        withdrawnAmount += amount;
        feeAmount = 0;

        assert(WCRO.transfer(feeTo, amount));
    }

    function updateDelegate(uint256 amount) external onlyOwner {
        require(amount                            <  (depositedAmount-withdrawnAmount), "Delegation should be less than totalDeposit");
        require((depositedAmount-withdrawnAmount) >= (delegationAmount+amount)        , "depositedAmount should be larger than delegationAmount");
        delegationAmount += amount;
        _updateDelegationRatio();
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

        uint256 toWCROAmount = 0;

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

    function burn(uint256 amount) public whenNotPaused {
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
        fee = ( amount * (feeRate*holdDiscount/100) ) / 1e6;
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
        ptToken.burn(owner, transAmount);
        ytToken.burn(owner, transAmount);

        payable(owner).transfer(transAmount);
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
        fee = ( amount * (feeRate*holdDiscount/100) ) / 1e6;
        feeAmount += fee;

        uint256 transAmount = amount - fee;

        withdrawnAmount += transAmount;
        _updateDelegationRatio();

        if (eatPANOn) {
            uint256 burnAmount = eatPANAmount*holdDiscount/100;
            require(panBalance >= burnAmount, "PAN Token: burn amount exceeds balance");
            PanToken.burn(burnAmount);
        }

        ptToken.burn(owner, transAmount);
        ytToken.burn(owner, transAmount);

        assert(WCRO.transfer(owner, transAmount));
        emit BurnToWCRO(owner, transAmount);
    }

    function pause() external onlyOwner whenNotPaused {
        _pause();
        emit Pause();
    }

    function unpause() external onlyOwner whenPaused {
        _unpause();
        emit Unpause();
    }

}