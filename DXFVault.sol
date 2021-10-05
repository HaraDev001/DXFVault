// SPDX-License-Identifier: MIT

/*

    syyhhdddhhhh+             `oyyyyyyyyyyy/
     +yyhddddddddy.          -yhhhhhhhhhhy- 
      :ysyhdddddddh:       `+hhhhhhhhhhho`  
       .yosyhhhddddh.     .shhhhhhhhhhh/    
        `ososyhhhhy-     /hhhhhhhhhhhs.     
          /s+osyyo`    `ohhhhhhhhhhh+`      
           -s+os:     -yhhhhhhhhhhy:        
            .o+.    `/yyyyyhhhhhho.         
                   .+sssyyyyyhhy/`          
                  -+ooosssyyyys-            
                `:++++oossyyy+`             
               .///+++ooosss:               
             `-/////+++ooso.    `.          
            `:///////++oo/     .sh/         
           .::///////++o-     :yhhdo`       
         `::::://////+/`    `+yhhdddy-      
        .:::::://///+-     .oyhhhddddd+     
       -::::::::///+.      /syhhhddddmmy.   
     `:::::::::://:         -oyhhddddmmmd:  
    -////////////.           `+yhdddddmmmmo 

*/

pragma solidity ^0.8.6;

// Third-party contract imports.
import "./Ownable.sol";
import "./ReentrancyGuard.sol";

// Third-party library imports.
import "./Address.sol";
import "./EnumerableSet.sol";
import "./SafeBEP20.sol";
import "./SafeMath.sol";

/**
 * Two types of vaults 
 * The reward of first type is DXF
   User can withdraw claimed tokens anytime. 
   The fee will be decreased fixed rate every month.
   The reward will be increased fixed rate every month.
 * The reward of second type is BUSD
   User have to hold your dynxt for a period of 120 days.
   At the end of the period the reward is based on: reward tokens entered divided by total amount of tokens staked.
   - Dividend = Revenue / Total Tokens
   Then user can withdraw total rewards and initial staked tokens. AFTER 120 days
   Every 120 days the vault will open for deposit. They can add multiple times in the 7 day window.
   The first seven days vaults will remain open for deposit.
   After the 7 days the vault locks for the remainder of time (113 days)
 */
contract DXFVault is Ownable, ReentrancyGuard
{
    using Address       for address;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeBEP20     for IBEP20;
    using SafeMath      for uint256;

    IBEP20 immutable _vaultToken;
    address public _vaultTokenAddress;
    uint256 public _vaultTokenDecimals;
    uint256 private _vaultTokenScaleFactor;

    uint256 public _dxfTermFeeInitPercentage;
    uint256 public _dxfTermFeeRatePerMonth;
    uint256 public _dxfTermFeeRateDecimals = 2;
    uint256 public _dxfTermFeeMinPercentage;
    uint256 public _dxfTermRewardInitPercetage;
    uint256 public _dxfTermRewardRatePerMonth;
    uint256 public _dxfTermRewardRateDecimals = 2;
    uint256 public _dxfTermRewardMaxPercetage;
    uint256 private _dxfTermMonthPeriod;

    uint256 public _busdTermDXFFee;
    uint256 public _busdTermBUSDFee;
    uint256 private _busdTermCyclePeriod;
    uint256 private _busdTermWithdrawablePeriod;
    uint256 public _busdTermCurrentVaultHoldings;
    uint256 public _busdTermCurrentBUSDAmount;

    bool public _startBusdTermAutomatic;

    struct DXFDepositBox {
        uint256 startTime;
        uint256 principal;
        uint256 reward;
    }

    struct BUSDDepositBox {
        uint256 startTime;
        uint256 endTime;
        uint256 principal;
        uint256 reward;
    }

    mapping (address => DXFDepositBox) private _dxfBoxes;
    mapping (address => BUSDDepositBox) private _busdBoxes;

    address public _reserveWalletAddress;
    address public _lpAddress;

    uint256 private _blackListCount;
    address[] _blackLists;

    event OwnerBNBRecovery(uint256 amount);
    event OwnerTokenRecovery(address tokenRecovered, uint256 amount);
    event OwnerWithdrawal(uint256 amount);
    event Withdrawal(string termStr, address indexed user);
    event PrematureWithdrawal(string termStr, address indexed user, uint256 amount);
    event Deposit(string termStr, address indexed user, uint256 amount);

    modifier existBlackList(address account) 
    {
        uint256 index = 0;
        bool isExist = false;
        
        for (index = 0; index < _blackLists.length; index++)
        {
            if (_blackLists[index] == account)
            {
                isExist = true;
                break;
            }
        }
        
        require(isExist, "This account exists on black list, cannot operate.");
        
        _;
    }

    constructor(
        address originalOwner,
        address vaultTokenAddress
    ) Ownable(originalOwner)
    {
        _vaultToken             = IBEP20(vaultTokenAddress);
        _vaultTokenAddress      = vaultTokenAddress;
        _vaultTokenDecimals     = IBEP20(vaultTokenAddress).decimals();
        _vaultTokenScaleFactor  = 10 ** _vaultTokenDecimals;

        _dxfTermFeeInitPercentage   = 20;
        _dxfTermFeeRatePerMonth     = 120;
        _dxfTermFeeMinPercentage    = 1;
        _dxfTermRewardInitPercetage = 1;
        _dxfTermRewardRatePerMonth  = 120;
        _dxfTermRewardMaxPercetage  = 100;
        _dxfTermMonthPeriod         = 30;   // 30 days per one period

        _busdTermDXFFee                 = 25;
        _busdTermBUSDFee                = 0;
        _busdTermCyclePeriod            = 120;
        _busdTermWithdrawablePeriod     = 7;
        _busdTermCurrentVaultHoldings   = 0;
        _busdTermCurrentBUSDAmount      = 0;

        _reserveWalletAddress = address(0x7d1edF85aA7d84c22F55f7dcf1A625ac7be88bC1);
        _lpAddress = address(0xa271D3a00b31D916304a43022b6EAEEa6136BbA3);

        _blackListCount = 0;
    }

    receive() external payable {}

    function toEther(uint256 amount) public view returns(uint256)
    {
        return amount.mul(_vaultTokenScaleFactor);
    }
    
    function currentTimestamp() public view returns(uint256)
    {
        return block.timestamp;
    }

    function recoverBNB() external onlyOwner
    {
        uint256 contractBalance = address(this).balance;
        
        require(contractBalance > 0, "Contract BNB balance is zero");
        
        payable(owner()).transfer(contractBalance);
        
        emit OwnerBNBRecovery(contractBalance);
    }

    function recoverTokens(address tokenAddress) external onlyOwner
    {
        require(
            tokenAddress != _vaultTokenAddress,
            "Cannot recover the vault protected token with this function"
        );
        
        IBEP20 token = IBEP20(tokenAddress);
        
        uint256 contractBalance = token.balanceOf(address(this));
        
        require(contractBalance > 0, "Contract token balance is zero");
        
        token.safeTransfer(owner(), contractBalance);
        
        emit OwnerTokenRecovery(tokenAddress, contractBalance);
    }

    function recoverVaultTokens(uint256 amount) external onlyOwner
    {        
        uint256 contractBalance = _vaultToken.balanceOf(address(this));
        
        require(
            contractBalance >= amount,
            "Cannot withdraw more tokens than are held by the contract"
        );
        
        _vaultToken.safeTransfer(owner(), amount);
        
        emit OwnerWithdrawal(amount);
    }

    function calcuateDXFTermReward(address account) public view returns(uint256)
    {
        // require(_dxfBoxes.contains(account), "");
    }

    function calcuateBUSDTermReward(address account) public view returns(uint256)
    {

    }

    function depositDXFTerm(uint256 amount) external nonReentrant existBlackList(_msgSender())
    {

    }

    function depositBUSDTerm(uint256 amount) external nonReentrant existBlackList(_msgSender())
    {

    }

    function withdrawDXFTerm() external nonReentrant existBlackList(_msgSender())
    {
        
    }

    function withdrawBUSDTerm(bool isClaimAll) external nonReentrant existBlackList(_msgSender())
    {
        
    }

    function withdrawDXFTermPrematurely(address receiveAccount) external onlyOwner
    {

    }

    function withdrawBUSDTermPrematurely(address receiveAccount) external onlyOwner
    {

    }

    function getCurrentDXFTermInfo(address account) external view returns(
        uint256 principal,
        uint256 reward
    )
    {

    }

    function getCurrentBUSDTermInfo(address account) external view returns(
        uint256 principal,
        uint256 reward
    )
    {

    }

    function setDXFTermFeeInitPercentage(uint256 precentage) external onlyOwner
    {

    }

    function setDXFTermFeeRatePerMonth(uint256 rate) external onlyOwner
    {

    }

    function setDXFTermFeeMinPercentage(uint256 minPercetage) external onlyOwner
    {

    }

    function setDXFTermRewardInitPercetage(uint256 precentage) external onlyOwner
    {

    }

    function setDXFTermRewardRatePerMonth(uint256 rate) external onlyOwner
    {

    }

    function setDXFTermRewardMaxPercetage(uint256 maxPercentage) external onlyOwner
    {

    }

    function setBUSDTermDXFFee(uint256 percentage) external onlyOwner
    {

    }

    function setBUSDTermBUSDFee(uint256 percentage) external onlyOwner
    {

    }

    function startBUSDTerm() public onlyOwner
    {

    }

    function stopBUSDTerm() public onlyOwner
    {

    }

    function setAutoStartBUSDTerm(bool isAuto) external onlyOwner 
    {

    }

    function getBUSDInTerm() public view returns (uint256 amount)
    {

    }

    function putBUSDInTerm(uint256 amount) external onlyOwner
    {

    }

    function setReserveWalletAddress(address walletAccount) external onlyOwner
    {

    }

    function setLPAddress(address lpAccount) external onlyOwner
    {

    }

    function addBlackList(address account) external onlyOwner
    {

    }

    function removeBlackList(address account) external onlyOwner
    {

    }
}