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

import './DateTimeLibrary.sol';

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

    uint256 public _dxfTermFeeInitPercentage;   // unit is gwei temporarily, 100% = 100 gwei
    uint256 public _dxfTermFeeRatePerMonth;     // unit is gwei temporarily
    uint256 public _dxfTermFeeMinPercentage;    // unit is gwei temporarily, 100% = 100 gwei
    uint256 public _dxfTermRewardInitPercetage; // unit is gwei temporarily, 100% = 100 gwei
    uint256 public _dxfTermRewardRatePerMonth;  // unit is gwei temporarily
    uint256 public _dxfTermRewardMaxPercetage;  // unit is gwei temporarily, 100% = 100 gwei
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
        uint256 lastWithdrawAmount;
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
    EnumerableSet.AddressSet _blackLists;

    event OwnerBNBRecovery(uint256 amount);
    event OwnerTokenRecovery(address tokenRecovered, uint256 amount);
    event OwnerWithdrawal(uint256 amount);
    event Withdrawal(string termStr, address indexed user, uint256 amount);
    event EmergencyWithdrawal(string termStr, address indexed user, uint256 amount);
    event Deposit(string termStr, address indexed user, uint256 amount);

    modifier existBlackList(address account) 
    {
        require(_blackLists.contains(account), "This account exists on black list, cannot operate.");
        
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

        _dxfTermFeeInitPercentage   = 20 gwei;
        _dxfTermFeeRatePerMonth     = 1.2 gwei;
        _dxfTermFeeMinPercentage    = 1 gwei;
        _dxfTermRewardInitPercetage = 1 gwei;
        _dxfTermRewardRatePerMonth  = 1.2 gwei;
        _dxfTermRewardMaxPercetage  = 100 gwei;
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

    // return value unit is ether = 10 ** 18
    function calculateDXFTermReward(address account) public view returns(uint256)
    {
        require(_dxfBoxes[account].startTime != 0, "This address did not deposited yet.");

        uint256 totalReward = 0;

        DXFDepositBox memory tempBox = _dxfBoxes[account];
        uint256 diffDays = DateTimeLibrary.diffDays(tempBox.startTime, block.timestamp);
        uint256 diffPeriods = diffDays / _dxfTermMonthPeriod;
        uint256 modPeriods = diffDays % _dxfTermMonthPeriod;

        uint256 percentage = _dxfTermRewardInitPercetage;
        uint256 tempPeriod = 0;

        while(diffPeriods > tempPeriod) {
            percentage = percentage * _dxfTermRewardRatePerMonth / 1 gwei;
            if (percentage > _dxfTermRewardMaxPercetage)
            {
                percentage = _dxfTermRewardMaxPercetage;
            }
            totalReward += tempBox.principal * percentage / 1 gwei;

            tempPeriod++;
        }

        if (modPeriods > 0)
        {
            percentage = percentage * _dxfTermRewardRatePerMonth / 1 gwei;
            if (percentage > _dxfTermRewardMaxPercetage)
            {
                percentage = _dxfTermRewardMaxPercetage;
            }
            uint256 tempReward = (tempBox.principal * percentage * modPeriods / _dxfTermMonthPeriod) / 1 gwei;

            totalReward += tempReward;
        }

        totalReward = totalReward / 100;

        return totalReward;
    }

    // return value unit is ether = 10 ** 18
    function calculateDXFTermFeePercent(address account) private view returns(uint256)
    {
        require(_dxfBoxes[account].startTime != 0, "This address did not deposited yet.");

        DXFDepositBox memory tempBox = _dxfBoxes[account];
        uint256 diffDays = DateTimeLibrary.diffDays(tempBox.startTime, block.timestamp);
        uint256 diffPeriods = diffDays / _dxfTermMonthPeriod;
        uint256 modPeriods = diffDays % _dxfTermMonthPeriod;

        if (modPeriods > 0) 
        {
            diffPeriods++;
        }

        uint256 percentage = _dxfTermFeeInitPercentage;
        uint256 tempPeriod = 0;

        while(diffPeriods > tempPeriod) {
            percentage = percentage * 1 gwei / _dxfTermFeeRatePerMonth;
            if (percentage < _dxfTermFeeMinPercentage)
            {
                percentage = _dxfTermFeeMinPercentage;
            }

            tempPeriod++;
        }

        return percentage;
    }

    function calculateBUSDTermReward(address account) public view returns(uint256)
    {

    }

    function isExistCurrentAddressInDXFTerm() public view returns(bool)
    {
        return _dxfBoxes[_msgSender()].startTime != 0;
    }

    function depositDXFTerm(uint256 amount) external nonReentrant existBlackList(_msgSender())
    {
        require(amount > 0, "The amount to deposit cannot be zero");
        require(_dxfBoxes[_msgSender()].startTime == 0, "This address already deposited.");

        _vaultToken.safeTransferFrom(
            address(_msgSender()),
            address(this),
            amount
        );

        DXFDepositBox storage tempBox = _dxfBoxes[_msgSender()];
        tempBox.startTime = block.timestamp;
        tempBox.principal = amount;
        tempBox.reward = 0;
        tempBox.lastWithdrawAmount = 0;

        emit Deposit("DXFDepositBox", _msgSender(), amount);
    }

    function depositBUSDTerm(uint256 amount) external nonReentrant existBlackList(_msgSender())
    {

    }

    function withdrawDXFTerm(bool isClaimAll) external nonReentrant existBlackList(_msgSender())
    {
        require(_dxfBoxes[_msgSender()].startTime != 0, "This address did not deposited yet.");
        
        DXFDepositBox storage tempBox = _dxfBoxes[_msgSender()];
        
        uint256 contractBalance = _vaultToken.balanceOf(address(this));
        require(
            contractBalance >= tempBox.principal,
            "Contract contains insufficient tokens to match this withdrawal attempt"
        );

        uint256 reward = calculateDXFTermReward(_msgSender());
        uint256 feePercent = calculateDXFTermFeePercent(_msgSender());

        uint256 feeForPrincipal = (tempBox.principal * feePercent / 1 gwei) / 100;
        uint256 feeForReward = ((reward - tempBox.lastWithdrawAmount) * feePercent / 1 gwei) / 100;

        // Mint to the reward to msg sender
        _vaultToken.safeMint(
            address(this),
            _msgSender(),
            reward - tempBox.lastWithdrawAmount - feeForReward
        );

        // Transfer feeForPrincipal to reserve wallet address
        _vaultToken.safeTransfer(
            _reserveWalletAddress,
            feeForPrincipal
        );

        tempBox.lastWithdrawAmount = reward;
        
        uint256 withdrawAmount = reward - tempBox.lastWithdrawAmount;
        if (isClaimAll)
        {
            // Withdraw principal to msg sender
            _vaultToken.safeTransfer(
                _msgSender(),
                tempBox.principal - feeForPrincipal
            );

            delete _dxfBoxes[_msgSender()];

            withdrawAmount += tempBox.principal;
        }

        emit Withdrawal("DXFDepositBox", _msgSender(), withdrawAmount);
    }

    function withdrawBUSDTerm(bool isClaimAll) external nonReentrant existBlackList(_msgSender())
    {

    }

    function withdrawDXFTermEmergency(address receiveAccount) external onlyOwner
    {
        require(_dxfBoxes[_msgSender()].startTime != 0, "This address did not deposited yet.");
        
        DXFDepositBox storage tempBox = _dxfBoxes[_msgSender()];
        
        uint256 contractBalance = _vaultToken.balanceOf(address(this));
        require(
            contractBalance >= tempBox.principal,
            "Contract contains insufficient tokens to match this withdrawal attempt"
        );

        _vaultToken.safeTransferFrom(
            address(this),
            receiveAccount,
            tempBox.principal
        );

        delete _dxfBoxes[receiveAccount];

        emit EmergencyWithdrawal("DXFDepositBox", receiveAccount, tempBox.principal);
    }

    function withdrawBUSDTermEmergency(address receiveAccount) external onlyOwner
    {

    }

    function getCurrentDXFTermInfo(address account) external existBlackList(account) view returns(uint256, uint256)
    {
        require(_dxfBoxes[account].startTime != 0, "This address did not deposited yet.");
        
        DXFDepositBox storage tempBox = _dxfBoxes[account];

        uint256 reward = calculateDXFTermReward(account);
        uint256 feePercent = calculateDXFTermFeePercent(account);
        uint256 feeForReward = ((reward - tempBox.lastWithdrawAmount) * feePercent / 1 gwei) / 100;

        uint256 principal = tempBox.principal;
        uint256 rewardRes = reward - tempBox.principal - feeForReward;
        
        return (principal, rewardRes);
    }

    function getCurrentBUSDTermInfo(address account) external view returns(
        uint256 principal,
        uint256 reward
    )
    {

    }

    function setDXFTermFeeInitPercentage(uint256 percentage) external onlyOwner
    {
        require(percentage > 0, "The initialization percentage cannot be zero");
        _dxfTermFeeInitPercentage = percentage;  
    }

    function setDXFTermFeeRatePerMonth(uint256 rate) external onlyOwner
    {
        require(rate > 0, "The rate cannot be zero");
        _dxfTermFeeRatePerMonth = rate;    
    }

    function setDXFTermFeeMinPercentage(uint256 minPercetage) external onlyOwner
    {
        require(minPercetage > 0, "The minimum percentage cannot be zero");
        _dxfTermFeeMinPercentage = minPercetage;   
    }

    function setDXFTermRewardInitPercetage(uint256 percentage) external onlyOwner
    {
        require(percentage > 0, "The initialization percentage cannot be zero");
        _dxfTermRewardInitPercetage = percentage;
    }

    function setDXFTermRewardRatePerMonth(uint256 rate) external onlyOwner
    {
        require(rate > 0, "The rate cannot be zero");
        _dxfTermRewardRatePerMonth = rate; 
    }

    function setDXFTermRewardMaxPercetage(uint256 maxPercentage) external onlyOwner
    {
        require(maxPercentage > 0, "The maximum percentage cannot be zero");
        _dxfTermRewardMaxPercetage = maxPercentage; 
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
        _reserveWalletAddress = walletAccount;
    }

    function setLPAddress(address lpAccount) external onlyOwner
    {
        _lpAddress = lpAccount;
    }

    function addBlackList(address account) external onlyOwner
    {
        require(!_blackLists.contains(account), "Already added on Blacklist.");
        _blackLists.add(account);
    }

    function removeBlackList(address account) external onlyOwner existBlackList(account)
    {
        _blackLists.remove(account);
    }
}