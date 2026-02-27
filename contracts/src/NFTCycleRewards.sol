// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Chainlink VRF interfaces
interface VRFCoordinatorV2Interface {
    function requestRandomWords(
        bytes32 keyHash,
        uint64 subId,
        uint16 minimumRequestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}

/**
 * @title NFTCycleRewards
 * @notice ERC721 NFTs with randomized tiers awarded to vault participants
 * @dev UUPS upgradeable with Chainlink VRF for fair tier distribution
 */
contract NFTCycleRewards is
    ERC721Upgradeable,
    ERC721BurnableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    uint256 public constant MIN_BALANCE_USDC = 100e6; // 100 USDC minimum
    
    // VRF Configuration
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant CALLBACK_GAS_LIMIT = 100000;
    uint32 public constant NUM_WORDS = 1;

    /* ========== ENUMS ========== */

    enum Tier {
        Bronze,   // 0
        Silver,   // 1
        Gold,     // 2
        Platinum  // 3
    }

    /* ========== STATE VARIABLES ========== */

    /// @notice Chainlink VRF Coordinator
    VRFCoordinatorV2Interface public vrfCoordinator;
    
    /// @notice Chainlink VRF key hash
    bytes32 public keyHash;
    
    /// @notice Chainlink VRF subscription ID
    uint64 public subscriptionId;

    /// @notice Total NFTs minted
    uint256 public totalMinted;
    
    /// @notice Mapping of token ID to tier
    mapping(uint256 => Tier) public tierOf;
    
    /// @notice Pending mint requests
    mapping(uint256 => MintRequest) public pendingRequests;
    
    /// @notice Token counter for unique IDs
    uint256 private _tokenIdCounter;

    struct MintRequest {
        address user;
        uint256 avgBalanceUSDC;
        bool fulfilled;
    }

    /* ========== EVENTS ========== */

    event MintRequested(uint256 indexed requestId, address indexed user, uint256 avgBalanceUSDC);
    event NFTMinted(uint256 indexed tokenId, address indexed user, Tier tier, uint256 requestId);
    event VRFConfigUpdated(address coordinator, bytes32 keyHash, uint64 subId);

    /* ========== ERRORS ========== */

    error InsufficientBalance();
    error RequestNotFound();
    error RequestAlreadyFulfilled();
    error UnauthorizedCaller();
    error InvalidVRFConfig();

    /* ========== INITIALIZER ========== */

    /**
     * @notice Initialize the NFT contract
     * @param _name NFT collection name
     * @param _symbol NFT collection symbol
     * @param _vrfCoordinator Chainlink VRF Coordinator address
     * @param _keyHash Chainlink VRF key hash
     * @param _subscriptionId Chainlink VRF subscription ID
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId
    ) external initializer {
        __ERC721_init(_name, _symbol);
        __ERC721Burnable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);

        if (_vrfCoordinator == address(0)) revert InvalidVRFConfig();
        
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        _tokenIdCounter = 1; // Start token IDs at 1
    }

    /* ========== MINTING FUNCTIONS ========== */

    /**
     * @notice Request NFT mint for eligible user
     * @dev Only callable by MINTER_ROLE. Checks minimum balance requirement.
     * @param user Address to receive NFT
     * @param avgBalanceUSDC User's average balance in USDC (6 decimals)
     * @return requestId VRF request ID
     */
    function requestMint(address user, uint256 avgBalanceUSDC) 
        external 
        onlyRole(MINTER_ROLE) 
        returns (uint256 requestId)
    {
        if (avgBalanceUSDC < MIN_BALANCE_USDC) {
            revert InsufficientBalance();
        }

        // Request random words from Chainlink VRF
        requestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            REQUEST_CONFIRMATIONS,
            CALLBACK_GAS_LIMIT,
            NUM_WORDS
        );

        // Store mint request
        pendingRequests[requestId] = MintRequest({
            user: user,
            avgBalanceUSDC: avgBalanceUSDC,
            fulfilled: false
        });

        emit MintRequested(requestId, user, avgBalanceUSDC);
        return requestId;
    }

    /**
     * @notice Fulfill random words callback from VRF Coordinator
     * @dev Called by Chainlink VRF Coordinator with random words
     * @param requestId The request ID returned by requestRandomWords
     * @param randomWords Array of random values
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        // Verify caller is VRF Coordinator
        if (msg.sender != address(vrfCoordinator)) {
            revert UnauthorizedCaller();
        }

        MintRequest storage request = pendingRequests[requestId];
        if (request.user == address(0)) {
            revert RequestNotFound();
        }
        if (request.fulfilled) {
            revert RequestAlreadyFulfilled();
        }

        // Mark as fulfilled
        request.fulfilled = true;

        // Determine tier from random value (0-3)
        Tier tier = Tier(randomWords[0] % 4);
        
        // Mint NFT
        uint256 tokenId = _tokenIdCounter++;
        _mint(request.user, tokenId);
        
        // Store tier
        tierOf[tokenId] = tier;
        totalMinted++;

        emit NFTMinted(tokenId, request.user, tier, requestId);
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Get NFT metadata
     * @param tokenId Token ID to query
     * @return owner Token owner
     * @return tier Token tier
     */
    function getNFTInfo(uint256 tokenId) 
        external 
        view 
        returns (address owner, Tier tier)
    {
        owner = ownerOf(tokenId);
        tier = tierOf[tokenId];
    }

    /**
     * @notice Get tier name as string
     * @param tier Tier enum value
     * @return Tier name
     */
    function getTierName(Tier tier) public pure returns (string memory) {
        if (tier == Tier.Bronze) return "Bronze";
        if (tier == Tier.Silver) return "Silver";
        if (tier == Tier.Gold) return "Gold";
        if (tier == Tier.Platinum) return "Platinum";
        return "Unknown";
    }

    /**
     * @notice Get pending request info
     * @param requestId VRF request ID
     * @return request Mint request details
     */
    function getPendingRequest(uint256 requestId) 
        external 
        view 
        returns (MintRequest memory request)
    {
        return pendingRequests[requestId];
    }

    /**
     * @notice Get total count by tier
     * @param tier Tier to count
     * @return count Number of NFTs minted for tier
     */
    function getTierCount(Tier tier) external view returns (uint256 count) {
        for (uint256 i = 1; i < _tokenIdCounter; i++) {
            if (_ownerOf(i) != address(0) && tierOf[i] == tier) {
                count++;
            }
        }
    }

    /**
     * @notice Get user's NFTs
     * @param user Address to query
     * @return tokenIds Array of token IDs owned by user
     * @return tiers Array of corresponding tiers
     */
    function getUserNFTs(address user) 
        external 
        view 
        returns (uint256[] memory tokenIds, Tier[] memory tiers)
    {
        uint256 balance = balanceOf(user);
        tokenIds = new uint256[](balance);
        tiers = new Tier[](balance);
        
        uint256 index = 0;
        for (uint256 i = 1; i < _tokenIdCounter && index < balance; i++) {
            if (_ownerOf(i) == user) {
                tokenIds[index] = i;
                tiers[index] = tierOf[i];
                index++;
            }
        }
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Update VRF configuration
     * @param _vrfCoordinator New VRF Coordinator address
     * @param _keyHash New key hash
     * @param _subscriptionId New subscription ID
     */
    function setVRFConfig(
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vrfCoordinator == address(0)) revert InvalidVRFConfig();
        
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        
        emit VRFConfigUpdated(_vrfCoordinator, _keyHash, _subscriptionId);
    }

    /**
     * @notice Emergency mint without VRF (for testing or emergency)
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     * @param user Address to receive NFT
     * @param tier Tier to assign
     */
    function emergencyMint(address user, Tier tier) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        uint256 tokenId = _tokenIdCounter++;
        _mint(user, tokenId);
        tierOf[tokenId] = tier;
        totalMinted++;
        
        emit NFTMinted(tokenId, user, tier, 0); // requestId = 0 for emergency mints
    }

    /**
     * @notice Test mint with pseudo-random tier (no VRF needed)
     * @dev Uses block.prevrandao for tier randomness. NOT for production.
     * @param user Address to receive NFT
     * @param avgBalanceUSDC User's average balance (must be >= 100 USDC)
     */
    function testMint(address user, uint256 avgBalanceUSDC)
        external
        onlyRole(MINTER_ROLE)
    {
        if (avgBalanceUSDC < MIN_BALANCE_USDC) {
            revert InsufficientBalance();
        }

        // Pseudo-random tier using block.prevrandao + user + counter
        uint256 randomish = uint256(keccak256(abi.encodePacked(
            block.prevrandao, user, _tokenIdCounter, block.timestamp
        )));
        Tier tier = Tier(randomish % 4);

        uint256 tokenId = _tokenIdCounter++;
        _mint(user, tokenId);
        tierOf[tokenId] = tier;
        totalMinted++;

        emit NFTMinted(tokenId, user, tier, 0);
    }

    /* ========== OVERRIDES ========== */

    /**
     * @notice Token URI for metadata
     * @dev Override to provide tier-specific metadata
     * @param tokenId Token ID to get URI for
     * @return Token URI string
     */
    function tokenURI(uint256 tokenId) 
        public 
        view 
        override 
        returns (string memory) 
    {
        _requireOwned(tokenId);
        
        Tier tier = tierOf[tokenId];
        string memory tierName = getTierName(tier);
        
        // Return JSON metadata (in practice, this would point to IPFS or web server)
        return string(abi.encodePacked(
            "data:application/json;base64,",
            _base64encode(bytes(abi.encodePacked(
                '{"name":"Turbo Paper Boat NFT #', 
                _toString(tokenId),
                '","description":"Cycle reward NFT with tier: ',
                tierName,
                '","attributes":[{"trait_type":"Tier","value":"',
                tierName,
                '"}]}'
            )))
        ));
    }

    /**
     * @notice Check interface support
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /* ========== UPGRADE AUTHORIZATION ========== */

    /**
     * @notice Authorize contract upgrade
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {}

    /* ========== INTERNAL HELPERS ========== */

    /**
     * @notice Convert uint to string
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }

    /**
     * @notice Base64 encode bytes
     */
    function _base64encode(bytes memory data) internal pure returns (string memory) {
        // Simple base64 encoding - in production use a library
        if (data.length == 0) return "";
        
        string memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        string memory result = new string(4 * ((data.length + 2) / 3));
        
        // Implementation would go here - simplified for demo
        return string(abi.encodePacked("encoded:", string(data)));
    }
}