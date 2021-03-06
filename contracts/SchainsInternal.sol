// SPDX-License-Identifier: AGPL-3.0-only

/*
    SchainsInternal.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
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
pragma experimental ABIEncoderV2;

import "./ConstantsHolder.sol";
import "./Nodes.sol";

interface ISkaleDKG {
    function openChannel(bytes32 schainId) external;
    function reopenChannel(bytes32 schainId) external;
    function deleteChannel(bytes32 schainId) external;
    function isChannelOpened(bytes32 schainId) external view returns (bool);
}

/**
 * @title SchainsInternal - contract contains all functionality logic to manage Schains
 */
contract SchainsInternal is Permissions {

    struct Schain {
        string name;
        address owner;
        uint indexInOwnerList;
        uint8 partOfNode;
        uint lifetime;
        uint32 startDate;
        uint startBlock;
        uint deposit;
        uint64 index;
    }

    /**
     * nodeIndex - index of Node which is in process of rotation(left from schain)
     * newNodeIndex - index of Node which is rotated(added to schain)
     * freezeUntil - time till which Node should be turned on
     * rotationCounter - how many rotations were on this schain
     */
    struct Rotation {
        uint nodeIndex;
        uint newNodeIndex;
        uint freezeUntil;
        uint rotationCounter;
    }

    struct LeavingHistory {
        bytes32 schainIndex;
        uint finishedRotation;
    }

    struct groupForSchain {
        uint[] nodesInGroup;
        uint[4] groupsPublicKey;
        bool lastSuccessfulDKG;
    }

    // mapping which contain all schains
    mapping (bytes32 => Schain) public schains;

    mapping (bytes32 => bool) public isSchainActive;

    mapping (bytes32 => groupForSchain) public schainsGroups;

    mapping (bytes32 => mapping (uint => bool)) private _exceptionsForGroups;
    // mapping shows schains by owner's address
    mapping (address => bytes32[]) public schainIndexes;
    // mapping shows schains which Node composed in
    mapping (uint => bytes32[]) public schainsForNodes;

    mapping (uint => uint[]) public holesForNodes;

    mapping (bytes32 => uint[]) public holesForSchains;

    mapping (bytes32 => Rotation) public rotations;

    mapping (uint => LeavingHistory[]) public leavingHistory;

    mapping (bytes32 => uint[4][]) public previousPublicKeys;

    // array which contain all schains
    bytes32[] public schainsAtSystem;

    uint64 public numberOfSchains;
    // total resources that schains occupied
    uint public sumOfSchainsResources;

    /**
     * @dev initializeSchain - initializes Schain
     * function could be run only by executor
     * @param name - SChain name
     * @param from - Schain owner
     * @param lifetime - initial lifetime of Schain
     * @param deposit - given amount of SKL
     */
    function initializeSchain(
        string calldata name,
        address from,
        uint lifetime,
        uint deposit) external allow("Schains")
    {
        bytes32 schainId = keccak256(abi.encodePacked(name));
        schains[schainId].name = name;
        schains[schainId].owner = from;
        schains[schainId].startDate = uint32(block.timestamp);
        schains[schainId].startBlock = block.number;
        schains[schainId].lifetime = lifetime;
        schains[schainId].deposit = deposit;
        schains[schainId].index = numberOfSchains;
        isSchainActive[schainId] = true;
        numberOfSchains++;
        schainsAtSystem.push(schainId);
    }

    function createGroupForSchain(
        bytes32 schainId,
        uint numberOfNodes,
        uint8 partOfNode
    )
        external
        allow("Schains")
        returns (uint[] memory)
    {
        schains[schainId].partOfNode = partOfNode;
        if (partOfNode > 0) {
            sumOfSchainsResources = sumOfSchainsResources.add(
                (128 / partOfNode) * numberOfNodes);
        }
        return _generateGroup(schainId, numberOfNodes);
    }

    /**
     * @dev setPublicKey - sets BLS master public key
     * function could be run only by SkaleDKG
     * @param schainId - Groups identifier
     * @param publicKeyx1 }
     * @param publicKeyy1 } parts of BLS master public key
     * @param publicKeyx2 }
     * @param publicKeyy2 }
     */
    function setPublicKey(
        bytes32 schainId,
        uint publicKeyx1,
        uint publicKeyy1,
        uint publicKeyx2,
        uint publicKeyy2) external allow("SkaleDKG")
    {
        if (!_isPublicKeyZero(schainId)) {
            uint[4] memory previousKey = schainsGroups[schainId].groupsPublicKey;
            previousPublicKeys[schainId].push(previousKey);
        }
        schainsGroups[schainId].lastSuccessfulDKG = true;
        schainsGroups[schainId].groupsPublicKey[0] = publicKeyx1;
        schainsGroups[schainId].groupsPublicKey[1] = publicKeyy1;
        schainsGroups[schainId].groupsPublicKey[2] = publicKeyx2;
        schainsGroups[schainId].groupsPublicKey[3] = publicKeyy2;
    }

    /**
     * @dev setSchainIndex - adds Schain's hash to owner
     * function could be run only by executor
     * @param schainId - hash by Schain name
     * @param from - Schain owner
     */
    function setSchainIndex(bytes32 schainId, address from) external allow("Schains") {
        schains[schainId].indexInOwnerList = schainIndexes[from].length;
        schainIndexes[from].push(schainId);
    }

    /**
     * @dev changeLifetime - changes Lifetime for Schain
     * function could be run only by executor
     * @param schainId - hash by Schain name
     * @param lifetime - time which would be added to lifetime of Schain
     * @param deposit - amount of SKL which payed for this time
     */
    function changeLifetime(bytes32 schainId, uint lifetime, uint deposit) external allow("Schains") {
        schains[schainId].deposit = schains[schainId].deposit.add(deposit);
        schains[schainId].lifetime = schains[schainId].lifetime.add(lifetime);
    }

    /**
     * @dev removeSchain - removes Schain from the system
     * function could be run only by executor
     * @param schainId - hash by Schain name
     * @param from - owner of Schain
     */
    function removeSchain(bytes32 schainId, address from) external allow("Schains") {
        isSchainActive[schainId] = false;
        uint length = schainIndexes[from].length;
        uint index = schains[schainId].indexInOwnerList;
        if (index != length - 1) {
            bytes32 lastSchainId = schainIndexes[from][length - 1];
            schains[lastSchainId].indexInOwnerList = index;
            schainIndexes[from][index] = lastSchainId;
        }
        schainIndexes[from].pop();

        // TODO:
        // optimize
        for (uint i = 0; i + 1 < schainsAtSystem.length; i++) {
            if (schainsAtSystem[i] == schainId) {
                schainsAtSystem[i] = schainsAtSystem[schainsAtSystem.length - 1];
                break;
            }
        }
        schainsAtSystem.pop();

        delete schains[schainId];
        numberOfSchains--;
    }

    function removeNodeFromSchain(
        uint nodeIndex,
        bytes32 schainHash
    )
        external 
        allowTwo("Schains", "SkaleDKG")
    {
        uint schainId = findSchainAtSchainsForNode(nodeIndex, schainHash);
        uint indexOfNode = _findNode(schainHash, nodeIndex);
        delete schainsGroups[schainHash].nodesInGroup[indexOfNode];

        uint length = schainsGroups[schainHash].nodesInGroup.length;
        if (indexOfNode == length - 1) {
            schainsGroups[schainHash].nodesInGroup.pop();
        } else {
            delete schainsGroups[schainHash].nodesInGroup[indexOfNode];
            if (holesForSchains[schainHash].length > 0 && holesForSchains[schainHash][0] > indexOfNode) {
                uint hole = holesForSchains[schainHash][0];
                holesForSchains[schainHash][0] = indexOfNode;
                holesForSchains[schainHash].push(hole);
            } else {
                holesForSchains[schainHash].push(indexOfNode);
            }
        }

        removeSchainForNode(nodeIndex, schainId);
    }

    function removeNodeFromExceptions(bytes32 schainHash, uint nodeIndex) external allow("Schains") {
        _exceptionsForGroups[schainHash][nodeIndex] = false;
    }

    function redirectOpenChannel(bytes32 schainId) external allow("Schains") {
        ISkaleDKG(_contractManager.getContract("SkaleDKG")).openChannel(schainId);
    }

    function startRotation(bytes32 schainIndex, uint nodeIndex) external allow("Schains") {
        ConstantsHolder constants = ConstantsHolder(_contractManager.getContract("ConstantsHolder"));
        rotations[schainIndex].nodeIndex = nodeIndex;
        rotations[schainIndex].freezeUntil = now + constants.rotationDelay();
    }

    function finishRotation(
        bytes32 schainIndex,
        uint nodeIndex,
        uint newNodeIndex)
        external allow("Schains")
    {
        ConstantsHolder constants = ConstantsHolder(_contractManager.getContract("ConstantsHolder"));
        leavingHistory[nodeIndex].push(LeavingHistory(schainIndex, now + constants.rotationDelay()));
        rotations[schainIndex].newNodeIndex = newNodeIndex;
        rotations[schainIndex].rotationCounter++;
        ISkaleDKG skaleDKG = ISkaleDKG(_contractManager.getContract("SkaleDKG"));
        skaleDKG.reopenChannel(schainIndex);
    }

    function removeRotation(bytes32 schainIndex) external allow("Schains") {
        delete rotations[schainIndex];
    }

    function skipRotationDelay(bytes32 schainIndex) external onlyOwner {
        rotations[schainIndex].freezeUntil = now;
    }

    /**
     * @dev deleteGroup - delete Group from Data contract
     * function could be run only by executor
     * @param schainId - Groups identifier
     */
    function deleteGroup(bytes32 schainId) external allow("Schains") {
        uint[4] memory previousKey = schainsGroups[schainId].groupsPublicKey;
        previousPublicKeys[schainId].push(previousKey);
        delete schainsGroups[schainId].groupsPublicKey;
        // delete channel
        ISkaleDKG skaleDKG = ISkaleDKG(_contractManager.getContract("SkaleDKG"));

        if (skaleDKG.isChannelOpened(schainId)) {
            skaleDKG.deleteChannel(schainId);
        }
        delete schainsGroups[schainId].nodesInGroup;
        delete schainsGroups[schainId];
    }

    /**
     * @dev setException - sets a Node like exception
     * function could be run only by executor
     * @param schainId - Groups identifier
     * @param nodeIndex - index of Node which would be notes like exception
     */
    function setException(bytes32 schainId, uint nodeIndex) external allow("Schains") {
        _exceptionsForGroups[schainId][nodeIndex] = true;
    }

    /**
     * @dev setNodeInGroup - adds Node to Group
     * function could be run only by executor
     * @param schainId - Groups 
     * @param nodeIndex - index of Node which would be added to the Group
     */
    function setNodeInGroup(bytes32 schainId, uint nodeIndex) external allow("Schains") {
        if (holesForSchains[schainId].length == 0) {
            schainsGroups[schainId].nodesInGroup.push(nodeIndex);
        } else {
            schainsGroups[schainId].nodesInGroup[holesForSchains[schainId][0]] = nodeIndex;
            uint min = uint(-1);
            uint index = 0;
            for (uint i = 1; i < holesForSchains[schainId].length; i++) {
                if (min > holesForSchains[schainId][i]) {
                    min = holesForSchains[schainId][i];
                    index = i;
                }
            }
            if (min == uint(-1)) {
                delete holesForSchains[schainId];
            } else {
                holesForSchains[schainId][0] = min;
                holesForSchains[schainId][index] =
                    holesForSchains[schainId][holesForSchains[schainId].length - 1];
                holesForSchains[schainId].pop();
            }
        }
    }

    function setGroupFailedDKG(bytes32 schainId) external allow("SkaleDKG") {
        schainsGroups[schainId].lastSuccessfulDKG = false;
    }

    function getRotation(bytes32 schainIndex) external view returns (Rotation memory) {
        return rotations[schainIndex];
    }

    function getLeavingHistory(uint nodeIndex) external view returns (LeavingHistory[] memory) {
        return leavingHistory[nodeIndex];
    }

    /**
     * @dev getSchains - gets all Schains at the system
     * @return array of hashes by Schain names
     */
    function getSchains() external view returns (bytes32[] memory) {
        return schainsAtSystem;
    }

    /**
     * @dev getSchainsPartOfNode - gets occupied space for given Schain
     * @param schainId - hash by Schain name
     * @return occupied space
     */
    function getSchainsPartOfNode(bytes32 schainId) external view returns (uint8) {
        return schains[schainId].partOfNode;
    }

    /**
     * @dev getSchainListSize - gets number of created Schains at the system by owner
     * @param from - owner of Schain
     * return number of Schains
     */
    function getSchainListSize(address from) external view returns (uint) {
        return schainIndexes[from].length;
    }

    /**
     * @dev getSchainIdsByAddress - gets array of hashes by Schain names which owned by `from`
     * @param from - owner of some Schains
     * @return array of hashes by Schain names
     */
    function getSchainIdsByAddress(address from) external view returns (bytes32[] memory) {
        return schainIndexes[from];
    }

    /**
     * @dev getSchainIdsForNode - returns array of hashes by Schain names,
     * which given Node composed
     * @param nodeIndex - index of Node
     * @return array of hashes by Schain names
     */
    function getSchainIdsForNode(uint nodeIndex) external view returns (bytes32[] memory) {
        return schainsForNodes[nodeIndex];
    }

    function getSchainOwner(bytes32 schainId) external view returns (address) {
        return schains[schainId].owner;
    }

    /**
     * @dev isSchainNameAvailable - checks is given name available
     * Need to delete - copy of web3.utils.soliditySha3
     * @param name - possible new name of Schain
     * @return if available - true, else - false
     */
    function isSchainNameAvailable(string calldata name) external view returns (bool) {
        bytes32 schainId = keccak256(abi.encodePacked(name));
        return schains[schainId].owner == address(0);
    }

    /**
     * @dev isTimeExpired - checks is Schain lifetime expired
     * @param schainId - hash by Schain name
     * @return if expired - true, else - false
     */
    function isTimeExpired(bytes32 schainId) external view returns (bool) {
        return schains[schainId].startDate.add(schains[schainId].lifetime) < block.timestamp;
    }

    /**
     * @dev isOwnerAddress - checks is `from` - owner of `schainId` Schain
     * @param from - owner of Schain
     * @param schainId - hash by Schain name
     * @return if owner - true, else - false
     */
    function isOwnerAddress(address from, bytes32 schainId) external view returns (bool) {
        return schains[schainId].owner == from;
    }

    function isSchainExist(bytes32 schainId) external view returns (bool) {
        return keccak256(abi.encodePacked(schains[schainId].name)) != keccak256(abi.encodePacked(""));
    }

    function getSchainName(bytes32 schainId) external view returns (string memory) {
        return schains[schainId].name;
    }

    function getActiveSchain(uint nodeIndex) external view returns (bytes32) {
        for (uint i = schainsForNodes[nodeIndex].length; i > 0; i--) {
            if (schainsForNodes[nodeIndex][i - 1] != bytes32(0)) {
                return schainsForNodes[nodeIndex][i - 1];
            }
        }
        return bytes32(0);
    }

    function getActiveSchains(uint nodeIndex) external view returns (bytes32[] memory activeSchains) {
        uint activeAmount = 0;
        for (uint i = 0; i < schainsForNodes[nodeIndex].length; i++) {
            if (schainsForNodes[nodeIndex][i] != bytes32(0)) {
                activeAmount++;
            }
        }

        uint cursor = 0;
        activeSchains = new bytes32[](activeAmount);
        for (uint i = schainsForNodes[nodeIndex].length; i > 0; i--) {
            if (schainsForNodes[nodeIndex][i - 1] != bytes32(0)) {
                activeSchains[cursor++] = schainsForNodes[nodeIndex][i - 1];
            }
        }
    }


    function isGroupFailedDKG(bytes32 schainId) external view returns (bool) {
        return !schainsGroups[schainId].lastSuccessfulDKG;
    }

    /**
     * @dev getNumberOfNodesInGroup - shows number of Nodes in Group
     * @param schainId - Groups identifier
     * @return number of Nodes in Group
     */
    function getNumberOfNodesInGroup(bytes32 schainId) external view returns (uint) {
        return schainsGroups[schainId].nodesInGroup.length;
    }

    /**
     * @dev getNodesInGroup - shows Nodes in Group
     * @param schainId - Groups identifier
     * @return array of indexes of Nodes in Group
     */
    function getNodesInGroup(bytes32 schainId) external view returns (uint[] memory) {
        return schainsGroups[schainId].nodesInGroup;
    }

    /*
     * @dev getGroupsPublicKey - shows Groups public key
     * @param schainId - Groups identifier
     * @return publicKey(x1, y1, x2, y2) - parts of BLS master public key
     */
    function getGroupsPublicKey(bytes32 schainId) external view returns (uint, uint, uint, uint) {
        return (
            schainsGroups[schainId].groupsPublicKey[0],
            schainsGroups[schainId].groupsPublicKey[1],
            schainsGroups[schainId].groupsPublicKey[2],
            schainsGroups[schainId].groupsPublicKey[3]
        );
    }

    function getPreviousGroupsPublicKey(bytes32 schainId) external view returns (uint, uint, uint, uint) {
        uint length = previousPublicKeys[schainId].length;
        if (length == 0) {
            return (0, 0, 0, 0);
        }
        return (
            previousPublicKeys[schainId][length - 1][0],
            previousPublicKeys[schainId][length - 1][1],
            previousPublicKeys[schainId][length - 1][2],
            previousPublicKeys[schainId][length - 1][3]
        );
    }

    function isAnyFreeNode(bytes32 schainId) external view returns (bool) {
        Nodes nodes = Nodes(_contractManager.getContract("Nodes"));
        uint8 space = schains[schainId].partOfNode;
        uint[] memory nodesWithFreeSpace = nodes.getNodesWithFreeSpace(space);
        for (uint i = 0; i < nodesWithFreeSpace.length; i++) {
            if (_isCorrespond(schainId, nodesWithFreeSpace[i])) {
                return true;
            }
        }
        return false;
    }

    function checkException(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        return _exceptionsForGroups[schainId][nodeIndex];
    }

    function initialize(address newContractsAddress) public override initializer {
        Permissions.initialize(newContractsAddress);

        numberOfSchains = 0;
        sumOfSchainsResources = 0;
    }

    /**
     * @dev addSchainForNode - adds Schain hash to Node
     * function could be run only by executor
     * @param nodeIndex - index of Node
     * @param schainId - hash by Schain name
     */
    function addSchainForNode(uint nodeIndex, bytes32 schainId) public allow("Schains") {
        if (holesForNodes[nodeIndex].length == 0) {
            schainsForNodes[nodeIndex].push(schainId);
        } else {
            schainsForNodes[nodeIndex][holesForNodes[nodeIndex][0]] = schainId;
            uint min = uint(-1);
            uint index = 0;
            for (uint i = 1; i < holesForNodes[nodeIndex].length; i++) {
                if (min > holesForNodes[nodeIndex][i]) {
                    min = holesForNodes[nodeIndex][i];
                    index = i;
                }
            }
            if (min == uint(-1)) {
                delete holesForNodes[nodeIndex];
            } else {
                holesForNodes[nodeIndex][0] = min;
                holesForNodes[nodeIndex][index] = holesForNodes[nodeIndex][holesForNodes[nodeIndex].length - 1];
                holesForNodes[nodeIndex].pop();
            }
        }
    }

    /**
     * @dev removesSchainForNode - clean given Node of Schain
     * function could be run only by executor
     * @param nodeIndex - index of Node
     * @param schainIndex - index of Schain in schainsForNodes array by this Node
     */
    function removeSchainForNode(uint nodeIndex, uint schainIndex) public allowTwo("Schains", "SkaleDKG") {
        uint length = schainsForNodes[nodeIndex].length;
        if (schainIndex == length - 1) {
            schainsForNodes[nodeIndex].pop();
        } else {
            schainsForNodes[nodeIndex][schainIndex] = bytes32(0);
            if (holesForNodes[nodeIndex].length > 0 && holesForNodes[nodeIndex][0] > schainIndex) {
                uint hole = holesForNodes[nodeIndex][0];
                holesForNodes[nodeIndex][0] = schainIndex;
                holesForNodes[nodeIndex].push(hole);
            } else {
                holesForNodes[nodeIndex].push(schainIndex);
            }
        }
    }

    /**
     * @dev getLengthOfSchainsForNode - returns number of Schains which contain given Node
     * @param nodeIndex - index of Node
     * @return number of Schains
     */
    function getLengthOfSchainsForNode(uint nodeIndex) public view returns (uint) {
        return schainsForNodes[nodeIndex].length;
    }

    /**
     * @dev findSchainAtSchainsForNode - finds index of Schain at schainsForNode array
     * @param nodeIndex - index of Node at common array of Nodes
     * @param schainId - hash of name of Schain
     * @return index of Schain at schainsForNode array
     */
    function findSchainAtSchainsForNode(uint nodeIndex, bytes32 schainId) public view returns (uint) {
        uint length = getLengthOfSchainsForNode(nodeIndex);
        for (uint i = 0; i < length; i++) {
            if (schainsForNodes[nodeIndex][i] == schainId) {
                return i;
            }
        }
        return length;
    }

    function isEnoughNodes(bytes32 schainId) public view returns (uint[] memory result) {
        Nodes nodes = Nodes(_contractManager.getContract("Nodes"));
        uint8 space = schains[schainId].partOfNode;
        uint[] memory nodesWithFreeSpace = nodes.getNodesWithFreeSpace(space);
        uint counter = 0;
        for (uint i = 0; i < nodesWithFreeSpace.length; i++) {
            if (!_isCorrespond(schainId, nodesWithFreeSpace[i])) {
                counter++;
            }
        }
        if (counter < nodesWithFreeSpace.length) {
            result = new uint[](nodesWithFreeSpace.length.sub(counter));
            counter = 0;
            for (uint i = 0; i < nodesWithFreeSpace.length; i++) {
                if (_isCorrespond(schainId, nodesWithFreeSpace[i])) {
                    result[counter] = nodesWithFreeSpace[i];
                    counter++;
                }
            }
        }
    }

    /**
     * @dev _generateGroup - generates Group for Schain
     * @param schainId - index of Group
     */
    function _generateGroup(bytes32 schainId, uint numberOfNodes) internal returns (uint[] memory nodesInGroup) {
        Nodes nodes = Nodes(_contractManager.getContract("Nodes"));
        uint8 space = schains[schainId].partOfNode;
        nodesInGroup = new uint[](numberOfNodes);

        uint[] memory possibleNodes = isEnoughNodes(schainId);
        require(possibleNodes.length >= nodesInGroup.length, "Not enough nodes to create Schain");
        uint ignoringTail = 0;
        uint random = uint(keccak256(abi.encodePacked(uint(blockhash(block.number - 1)), schainId)));
        for (uint i = 0; i < nodesInGroup.length; ++i) {
            uint index = random % (possibleNodes.length.sub(ignoringTail));
            uint node = possibleNodes[index];
            nodesInGroup[i] = node;
            _swap(possibleNodes, index, possibleNodes.length.sub(ignoringTail) - 1);
            ++ignoringTail;

            _exceptionsForGroups[schainId][node] = true;
            addSchainForNode(node, schainId);
            require(nodes.removeSpaceFromNode(node, space), "Could not remove space from Node");
        }

        // set generated group
        schainsGroups[schainId].nodesInGroup = nodesInGroup;
    }

    function _isPublicKeyZero(bytes32 schainId) internal view returns (bool) {
        return schainsGroups[schainId].groupsPublicKey[0] == 0 &&
            schainsGroups[schainId].groupsPublicKey[1] == 0 &&
            schainsGroups[schainId].groupsPublicKey[2] == 0 &&
            schainsGroups[schainId].groupsPublicKey[3] == 0;
    }

    function _isCorrespond(bytes32 schainId, uint nodeIndex) internal view returns (bool) {
        Nodes nodes = Nodes(_contractManager.getContract("Nodes"));
        return !_exceptionsForGroups[schainId][nodeIndex] && nodes.isNodeActive(nodeIndex);
    }

    function _swap(uint[] memory array, uint index1, uint index2) internal pure {
        uint buffer = array[index1];
        array[index1] = array[index2];
        array[index2] = buffer;
    }

    /**
     * @dev findNode - find local index of Node in Schain
     * @param schainId - Groups identifier
     * @param nodeIndex - global index of Node
     * @return local index of Node in Schain
     */
    function _findNode(bytes32 schainId, uint nodeIndex) internal view returns (uint) {
        uint[] memory nodesInGroup = schainsGroups[schainId].nodesInGroup;
        uint index;
        for (index = 0; index < nodesInGroup.length; index++) {
            if (nodesInGroup[index] == nodeIndex) {
                return index;
            }
        }
        return index;
    }

}
