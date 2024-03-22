// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Votes.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Wrapper.sol";

/// The goal of this contract is create a way to allow realm nft holders to get 
/// streamed {x} amount of $lords once they wrap their realms token to obtain vRealms.
/// Once they obtain vRealms, their votes are automatically self delegated and their stream starts counting.

/// Streams are maintened on a per token basis. So this means that when making claims on streams, it would
/// also need to be done one token at a time. The `claim` function however accepts an array of `tokenIds` so 
/// you can make claims on multiple tokens at once
///
/// the Flow struct simply maintains the details of the current flow i.e the flow rate of lords (per second)
/// as well as when that flow rate gets expired. A flow rate gets expired when a new one is added. 
/// This means we can change the stream flow rate and when it is changed, everyone's current stream ends 
/// and they only start using the new flow rate when they have claimed their current stream reward

contract RealmLordship is ERC721, EIP712, ERC721Votes, ERC721Wrapper, Ownable2Step {

    event FlowRateUpdated(uint16 indexed id, uint256 rate);
    event RewardClaimed(address indexed recipient, uint256 amount);

    error InvalidClaimer(address claimer);
    error InvalidDelegatee(address delegatee);
    
    struct Flow {
        uint256 rate; // flow rate per second
        uint256 endAt;
    }
    mapping(uint16 flowId => Flow) public flows;
    uint16 public currentFlowId;


    struct Stream {
        uint16 flowId;
        uint256 lastClaimAt;
    }
    mapping(uint256 tokenId => Stream) public streams;


    address public rewardTokenAddress;
    address public rewardPayerAddress;

    constructor(
        address _wrappedTokenAddress, 
        address _ownerAddress, 
        uint256 _flowRate, 
        address _rewardTokenAddress, 
        address _rewardPayerAddress
    ) 
        ERC721("vRealm", "vREALM") // todo@confirm name and symbol
        EIP712("vRealm", "1") 
        ERC721Wrapper(IERC721(_wrappedTokenAddress)) 
        Ownable(_ownerAddress)
    {
        // set flow rate
        _startNewFlow(_flowRate);

        // update reward meta
         _updateRewardTokenAddress(_rewardTokenAddress);
         _updateRewardPayerAddress(_rewardPayerAddress);

    }

    function updateFlowRate(uint256 rate) public onlyOwner {
        _endCurrentFlow();
        _startNewFlow(rate);
     }

    function updateRewardTokenAddress(address newRewardTokenAddress) public onlyOwner {
        _updateRewardTokenAddress(newRewardTokenAddress);
     }

    function updateRewardPayerAddress(address newRewardPayerAddress) public onlyOwner {
        _updateRewardPayerAddress(newRewardPayerAddress);
     }

    function claim(uint256[] calldata tokenIds) public {
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            address caller = _msgSender();
            if (caller == _ownerOf(tokenId)) {
                _claim(caller, tokenId);
            } else {
                revert InvalidClaimer(caller);
            }
        }
     }

    function delegate(address delegatee) public override {
        if (delegatee == address(0)){
            revert InvalidDelegatee(delegatee);
        }
        super.delegate(delegatee);
    }


    function _updateRewardTokenAddress(address _rewardTokenAddress) internal {
        rewardTokenAddress = _rewardTokenAddress;
    }

    function _updateRewardPayerAddress(address _rewardPayerAddress) internal {
        rewardPayerAddress = _rewardPayerAddress;
    }


    
    function _endCurrentFlow() internal {
        Flow storage flow = flows[currentFlowId];
        flow.endAt = block.timestamp;
    }

    function _startNewFlow(uint256 rate) internal {
        currentFlowId++;
        Flow memory newFlow = Flow({rate: rate, endAt: type(uint256).max});
        flows[currentFlowId] = newFlow;

        // emit event
        emit FlowRateUpdated(currentFlowId, rate);
     }



    function _streamedAmount(uint256 amountTime, uint256 rate) 
        internal 
        pure 
        returns (uint256)
    {
        return amountTime * rate;
     }

     
    function _claim(address recipient, uint256 tokenId) internal {
        if (recipient != address(0)) {
            Stream storage stream = streams[tokenId];
            if (stream.flowId != 0) {
                Flow storage flow = flows[stream.flowId];
                uint256 endStreamAt;
                if (block.timestamp >= flow.endAt) {
                    endStreamAt = flow.endAt;
                } else {
                    endStreamAt = block.timestamp;
                }

                uint256 amountTime = endStreamAt - stream.lastClaimAt;
                uint256 streamedAmount = _streamedAmount(amountTime, flow.rate);

                stream.lastClaimAt = block.timestamp;
                stream.flowId = currentFlowId;

                // interactions after effect
                if (streamedAmount > 0) {
                    IERC20(rewardTokenAddress)
                        .transferFrom(rewardPayerAddress, recipient, streamedAmount);
                    emit RewardClaimed(recipient, streamedAmount);
                }
            }
        }
     }


    function _stream(address oldOwner, address newOwner, uint256 tokenId) internal {
        Stream storage stream = streams[tokenId];
        if (stream.flowId != 0) {
            _claim(oldOwner, tokenId);
        }

        if (newOwner != address(0)) {
            stream.flowId = currentFlowId;
            stream.lastClaimAt = block.timestamp;
        }
     }


    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Votes)
        returns (address)
    {
        address previousOwner = super._update(to, tokenId, auth);

        if (to != address(0)) {
            // self delegate if recipient has no delegate
            if (delegates(to) == address(0)){
                 _delegate(to, to);
            }
            _stream(previousOwner, to, tokenId);
        }
        return previousOwner;
    }


    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Votes)
    {
        super._increaseBalance(account, value);
    }

}