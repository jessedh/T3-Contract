// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract T3Token is ERC20, Ownable {
    struct TransferMetadata {
        uint256 commitWindowEnd;
        uint256 halfLifeDuration;
        address originator;
        uint256 transferCount;
        bytes32 reversalHash;
    }

    mapping(address => TransferMetadata) public transferData;

    uint256 public halfLifeDuration = 3600;

    constructor(address initialOwner) ERC20("T3 Stablecoin", "T3") Ownable(initialOwner) {
        _mint(initialOwner, 1000000 * 10 ** decimals());
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        transferData[recipient] = TransferMetadata({
            commitWindowEnd: block.timestamp + halfLifeDuration,
            halfLifeDuration: halfLifeDuration,
            originator: _msgSender(),
            transferCount: transferData[recipient].transferCount + 1,
            reversalHash: keccak256(abi.encodePacked(_msgSender(), recipient, amount))
        });
        return true;
    }

    function reverseTransfer(address from, address to, uint256 amount) external {
        TransferMetadata memory metadata = transferData[from];

        require(
            _msgSender() == metadata.originator || _msgSender() == from,
            "T3: Only sender or recipient can reverse"
        );

        require(block.timestamp <= metadata.commitWindowEnd, "T3: Reversal window expired");

        bytes32 expectedHash = keccak256(abi.encodePacked(to, from, amount));
        require(expectedHash == metadata.reversalHash, "T3: Hash mismatch");

        _transfer(from, to, amount);
    }
}
