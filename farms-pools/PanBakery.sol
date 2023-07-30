// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

//import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.4.0/contracts/token/ERC20/ERC20.sol";
import "./PanToken.sol";

// Workbench with Governance.
contract PanBakery is ERC20('Creampan Bakery', 'BAKERY'), Ownable {
    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterBaker).
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }

    function burn(address _from ,uint256 _amount) public onlyOwner {
        _burn(_from, _amount);
    }

    // The PAN TOKEN!
    PanToken public pan;

    constructor (
        PanToken _pan
    ) public {
        pan = _pan;
    }

    // Safe PAN transfer function, just in case if rounding error causes pool to not have enough PANs.
    function safePanTransfer(address _to, uint256 _amount) public onlyOwner {
        uint256 panBal = pan.balanceOf(address(this));
        if (_amount > panBal) {
            pan.transfer(_to, panBal);
        } else {
            pan.transfer(_to, _amount);
        }
    }
}