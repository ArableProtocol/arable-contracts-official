// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library DistributeIterableMapping {
    struct DistributeMember {
        address addr; // address of a member
        uint256 allocation; // the allocation point of a member
        uint256 pending; // pending amount of a member that can be released any time
        uint256 totalReleased; // total released amount to the member
    }

    // Iterable mapping from address to DistributeMember;
    struct Map {
        address[] keys;
        mapping(address => DistributeMember) values;
        mapping(address => uint256) indexOf;
        mapping(address => bool) inserted;
    }

    function get(Map storage map, address key) internal view returns (DistributeMember storage) {
        return map.values[key];
    }

    function getKeyAtIndex(Map storage map, uint256 index) internal view returns (address) {
        return map.keys[index];
    }

    function size(Map storage map) internal view returns (uint256) {
        return map.keys.length;
    }

    function set(
        Map storage map,
        address key,
        DistributeMember memory val
    ) internal {
        if (map.inserted[key]) {
            map.values[key] = val;
        } else {
            map.inserted[key] = true;
            map.values[key] = val;
            map.indexOf[key] = map.keys.length;
            map.keys.push(key);
        }
    }

    function remove(Map storage map, address key) internal {
        if (!map.inserted[key]) {
            return;
        }

        delete map.inserted[key];
        delete map.values[key];

        uint256 index = map.indexOf[key];
        uint256 lastIndex = map.keys.length - 1;
        address lastKey = map.keys[lastIndex];

        map.indexOf[lastKey] = index;
        delete map.indexOf[key];

        map.keys[index] = lastKey;
        map.keys.pop();
    }
}
