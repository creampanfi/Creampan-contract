// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/access/Ownable.sol";

contract PanToken is ERC20("Creampan Token", "PAN"), Ownable {

    uint256 public initBlock;
    uint256 public constant blockPerDay = 16000;
    
    constructor (uint256 _initBlock) public {
        initBlock = _initBlock;
    }

    /// @dev Creates `_amount` token to `_to`. Must only be called by the owner (MasterBaker).
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }

    /// @dev Burn `_amount` token from `_from`. Can be called by anyone.
    function burn(uint256 _amount) public {
        address owner = _msgSender();
        _burn(owner, _amount);
    }

}
