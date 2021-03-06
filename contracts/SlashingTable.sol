// SPDX-License-Identifier: AGPL-3.0-only

/*
    SlashingTable.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Dmytro Stebaiev
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.8;

import "./Permissions.sol";

/**
 * @title Slashing Table
 * @dev This contract manages slashing conditions and penalties.
 */
contract SlashingTable is Permissions {
    mapping (uint => uint) private _penalties;

    /**
     * @dev Sets a penalty for a given offense
     * Only the owner can set penalties.
     *
     * @param offense string
     * @param penalty uint amount of slashing for the specified penalty
     */
    function setPenalty(string calldata offense, uint penalty) external onlyOwner {
        _penalties[uint(keccak256(abi.encodePacked(offense)))] = penalty;
    }

    /**
     * @dev Returns the penalty for a given offense
     *
     * @param offense string
     * @return uint amount of slashing for the specified penalty
     */
    function getPenalty(string calldata offense) external view returns (uint) {
        uint penalty = _penalties[uint(keccak256(abi.encodePacked(offense)))];
        return penalty;
    }

    function initialize(address contractManager) public override initializer {
        Permissions.initialize(contractManager);
    }
}
