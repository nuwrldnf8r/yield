// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.0 (token/common/ERC2981.sol)

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
//import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ERC2981.sol";

interface AccessToken{
    function balanceOf(address owner) external view returns (uint256 balance);
}

contract BitmartYieldToken is ERC721Enumerable, Ownable, ERC2981 {
    AccessToken private immutable _accessToken;

    struct FundInfo{
        uint256 sold;
        uint256 value;
        uint256 ts;
    }

    struct YieldInfo{
        uint256 numFundings;
        uint8 weight;
        bool active;
    }

    mapping(address => bool) private _minter;
    mapping(uint256 => string) private _metadata;
    mapping(uint256 => YieldInfo) private _yieldInfo; //tokenID => yield index
    mapping(uint256 => FundInfo) private _fundInfo; //index based on _numFundings => FundInfo

    uint256 private _numFundings;
    uint256 private _soldInitial;
    uint256 private _withdrawn;
    uint256 private _lastBalance;
    uint256 private _expiryTime = 5 minutes; //365 days
    uint256 private _fundProcessPeriod = 30 seconds;
    uint256 private _nextToken = 1;
    address private _expiredFundsAddress;
    uint256 private _lastExpiredIdx;
    
    modifier onlyMinter() {
        require(_minter[_msgSender()] || _msgSender()==owner(), "Caller is not the a minter");
        _;
    }

    constructor(address accessToken) ERC721("Bitmart Yield Token", "YBM"){
        _accessToken = AccessToken(accessToken);
        _expiredFundsAddress = _msgSender();
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function setMinter(address minter, bool hasAccess) public onlyOwner{
        _minter[minter] = hasAccess;
    }

    function setExpiredFundsAddress(address expiredFundsAddress) public onlyOwner{
        _expiredFundsAddress = expiredFundsAddress;
    }

    function mint(string calldata metaData, uint8 weight) public onlyMinter{
        _metadata[_nextToken] = metaData;
        _yieldInfo[_nextToken].weight = weight;
        _safeMint(owner(), _nextToken);
        _nextToken++;
    }

    function totalPaid() public view returns (uint256){
        return address(this).balance + _withdrawn;
    }

    function setProcessTimePeriod(uint256 period) public onlyOwner{
        _fundProcessPeriod = period;
    }

    function fundProcessPeriod() public view returns (uint256){
        return _fundProcessPeriod;
    }

    function processFunds() public {
        uint256 value = totalPaid() - _lastBalance;
        require(value>0,"Value cannot be zero");
        require(_soldInitial>0,"Can't fund with no holders");
        require(_numFundings==0 || (block.timestamp-_fundInfo[_numFundings-1].ts>=_fundProcessPeriod),"Processing time perid hasn't passed yet");
       _fundInfo[_numFundings] = FundInfo({
            sold: _soldInitial,
            value: value,
            ts: block.timestamp
       });
       _lastBalance = totalPaid() + _withdrawn;
       _numFundings++;
    }

    function getNumFunding() public view returns (uint256){
        return _numFundings;
    }

    function getFundingInfo(uint256 index) public view returns (FundInfo memory){
        require(index<_numFundings,"Index out of range");
        return _fundInfo[index];
    }

    function getExpiredBalance(uint256 tokenId) public view returns (uint256){
        require(_yieldInfo[tokenId].active,"TokenId not active");
        require(_accessToken.balanceOf(ownerOf(tokenId))>0,"Token owner has no Access tokens");
        uint256 start = _yieldInfo[tokenId].numFundings;
        if(start==_numFundings)return 0; //
        uint256 bal = 0;
        uint256 maxStart = block.timestamp - _expiryTime;
        for(uint i=start;i<_numFundings;i++){
            if(_fundInfo[i].ts>maxStart) break;
            bal += _fundInfo[i].value*_yieldInfo[tokenId].weight/_fundInfo[i].sold;
            
        }
        return bal;
    }

    function transferExpired(uint256 tokenId) public {
        require(_yieldInfo[tokenId].active,"TokenId not active");
        uint256 bal = getExpiredBalance(tokenId);
        require(bal>0,"No expired balance");
        uint256 lastExpiredIdx=_lastExpiredIdx;
        uint256 maxStart = block.timestamp - _expiryTime;
        for(uint256 i=_lastExpiredIdx;i<_numFundings;i++){
            if(_fundInfo[i].ts>maxStart)break;
            lastExpiredIdx = _fundInfo[i].ts;
        }
        _lastExpiredIdx = lastExpiredIdx;
        _yieldInfo[tokenId].numFundings = _lastExpiredIdx+1;
        payable(_expiredFundsAddress).transfer(bal);
    }

    function yieldBalance(uint256 tokenId) public view returns (uint256){
        require(_yieldInfo[tokenId].active,"TokenId not active");
        require(_accessToken.balanceOf(ownerOf(tokenId))>0,"Token owner has no Access tokens");
        uint256 start = _yieldInfo[tokenId].numFundings;
        if(start==_numFundings)return 0; //
        uint256 bal = 0;
        uint256 maxStart = block.timestamp - _expiryTime;
        for(uint i=start;i<_numFundings;i++){
            if(_fundInfo[i].ts>maxStart){
                bal += _fundInfo[i].value*_yieldInfo[tokenId].weight/_fundInfo[i].sold;
            }
        }
        return bal;
    }

    function yieldInfo(uint256 tokenId) public view returns (YieldInfo memory){
        require(_yieldInfo[tokenId].active,"TokenId not active");
        return _yieldInfo[tokenId];
    }

    function withdraw(uint256 tokenId) public {
        require(ownerOf(tokenId)==_msgSender(),"Not owner of token");
        uint256 bal = yieldBalance(tokenId);
        require(bal>0,"Balance cannot be zero");
        _yieldInfo[tokenId].numFundings = _numFundings;
        _withdrawn += bal;
        payable(_msgSender()).transfer(bal);
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
        return _metadata[tokenId];
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId);
        if(!_yieldInfo[tokenId].active && to !=owner()){
            _yieldInfo[tokenId].active = true;
            _yieldInfo[tokenId].numFundings = _numFundings;
            _soldInitial += _yieldInfo[tokenId].weight;
        }
    }

    receive() external payable{}
}

//FTM testnet: 0xe4A0935f20BdDC346EE7475c628Feb7f85F8E0D4
