// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;

// Third-party contract imports.
import "./Ownable.sol";
import "./ReentrancyGuard.sol";

// Third-party library imports.
import "./Address.sol";
import "./EnumerableSet.sol";
import "./SafeBEP20.sol";
import "./SafeMath.sol";

import "./DateTimeLibrary.sol";

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

    uint256 public _dxfTypeFeeInitPercentage;   // unit is gwei temporarily, 100% = 100 gwei
    uint256 public _dxfTypeFeeRatePerMonth;     // unit is gwei temporarily
    uint256 public _dxfTypeFeeMinPercentage;    // unit is gwei temporarily, 100% = 100 gwei
    uint256 public _dxfTypeRewardInitPercentage; // unit is gwei temporarily, 100% = 100 gwei
    uint256 public _dxfTypeRewardRatePerMonth;  // unit is gwei temporarily
    uint256 public _dxfTypeRewardMaxPercentage;  // unit is gwei temporarily, 100% = 100 gwei
    uint256 private _dxfTypeMonthPeriod;

    struct DXFDepositBox {
        uint256 startTime;
        uint256 principal;
        uint256 reward;
        uint256 lastWithdrawAmount;
    }

    mapping (address => DXFDepositBox) private _dxfBoxes;

    uint256 public _busdTypeDXFFeePercentage;
    uint256 public _busdTypeBUSDFeePercentage;
    uint256 private _busdTypeCyclePeriod;
    uint256 private _busdTypeWithdrawablePeriod;
    uint256 private _busdCycleTypeNum;
    bool private _busdTypeDepositEnableStatus;
    bool private _busdTypeWithdrawEnableStatus = false;
    bool private _busdTypeAutoStart = false;
    uint256 private _startBusdTypeAt;
    uint256 private _stopBusdTypeAt;
    uint256 private _maxPercentage = 100 gwei;
    bool public _startBusdTypeAutomatic;
    
    mapping (uint => uint) public _busdTypeCurrentVaultHoldings;
    mapping (uint => uint) public _busdTypeCurrentBUSDAmount;
    EnumerableSet.AddressSet _busdTypeUserList;

    mapping (address => uint256) private _busdDXFBoxes;
    mapping (uint256 => mapping (address => uint256)) private _busdRewardBoxes;
    
    address public _reserveWalletAddress;
    address public _lpAddress;

    EnumerableSet.AddressSet _blackLists;

    event OwnerBNBRecovery(uint256 amount);
    event OwnerTokenRecovery(address tokenRecovered, uint256 amount);
    event OwnerWithdrawal(uint256 amount);
    event Withdrawal(string str, address indexed user, uint256 amount);
    event EmergencyWithdrawal(string str, address indexed user, uint256 amount);
    event Deposit(string str, address indexed user, uint256 amount);

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

        _dxfTypeFeeInitPercentage   = 20 gwei;
        _dxfTypeFeeRatePerMonth     = 1.2 gwei;
        _dxfTypeFeeMinPercentage    = 1 gwei;
        _dxfTypeRewardInitPercentage = 1 gwei;
        _dxfTypeRewardRatePerMonth  = 1.2 gwei;
        _dxfTypeRewardMaxPercentage  = 100 gwei;
        _dxfTypeMonthPeriod         = 30;   // 30 days per one period

        _busdTypeDXFFeePercentage                 = 25 gwei;
        _busdTypeBUSDFeePercentage                = 0 gwei;
        _busdTypeCyclePeriod            = 120;
        _busdTypeWithdrawablePeriod     = 7;
        _busdTypeDepositEnableStatus = false;
        _busdTypeWithdrawEnableStatus = true;
        _reserveWalletAddress = address(0x7d1edF85aA7d84c22F55f7dcf1A625ac7be88bC1);
        _lpAddress = address(0xa271D3a00b31D916304a43022b6EAEEa6136BbA3);
    }

    receive() external payable {}

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
    function calculateDXFTypeReward(address account) public view returns(uint256)
    {
        require(_dxfBoxes[account].startTime != 0, "This address did not deposited yet.");

        uint256 totalReward = 0;

        DXFDepositBox memory tempBox = _dxfBoxes[account];
        uint256 diffDays = DateTimeLibrary.diffDays(tempBox.startTime, block.timestamp);
        uint256 diffPeriods = diffDays / _dxfTypeMonthPeriod;
        uint256 modPeriods = diffDays % _dxfTypeMonthPeriod;

        uint256 percentage = _dxfTypeRewardInitPercentage;
        uint256 tempPeriod = 0;

        while(diffPeriods > tempPeriod) {
            percentage = percentage * _dxfTypeRewardRatePerMonth / 1 gwei;
            if (percentage > _dxfTypeRewardMaxPercentage)
            {
                percentage = _dxfTypeRewardMaxPercentage;
            }
            totalReward += tempBox.principal * percentage / 1 gwei;

            tempPeriod++;
        }

        if (modPeriods > 0)
        {
            percentage = percentage * _dxfTypeRewardRatePerMonth / 1 gwei;
            if (percentage > _dxfTypeRewardMaxPercentage)
            {
                percentage = _dxfTypeRewardMaxPercentage;
            }
            uint256 tempReward = (tempBox.principal * percentage * modPeriods / _dxfTypeMonthPeriod) / 1 gwei;

            totalReward += tempReward;
        }

        totalReward = totalReward / 100;

        return totalReward;
    }

    // return value unit is ether = 10 ** 18
    function calculateDXFTypeFeePercent(address account) private view returns(uint256)
    {
        require(_dxfBoxes[account].startTime != 0, "This address did not deposited yet.");

        DXFDepositBox memory tempBox = _dxfBoxes[account];
        uint256 diffDays = DateTimeLibrary.diffDays(tempBox.startTime, block.timestamp);
        uint256 diffPeriods = diffDays / _dxfTypeMonthPeriod;
        uint256 modPeriods = diffDays % _dxfTypeMonthPeriod;

        if (modPeriods > 0) 
        {
            diffPeriods++;
        }

        uint256 percentage = _dxfTypeFeeInitPercentage;
        uint256 tempPeriod = 0;

        while(diffPeriods > tempPeriod) {
            percentage = percentage * 1 gwei / _dxfTypeFeeRatePerMonth;
            if (percentage < _dxfTypeFeeMinPercentage)
            {
                percentage = _dxfTypeFeeMinPercentage;
            }

            tempPeriod++;
        }

        return percentage;
    }

    function addBusdTypeUserList(address account) private 
    {
        if (!_busdTypeUserList.contains(account))
        {
            _busdTypeUserList.add(account);
        }
    } 

    function recalculateBUSDReward() private 
    {
        uint256 index = 0;
        for (index; index < _busdTypeUserList.length(); index++)
        {
            address account = _busdTypeUserList.at(index);
            _busdRewardBoxes[_busdCycleTypeNum][account] = (_busdDXFBoxes[account] * _busdTypeCurrentBUSDAmount[_busdCycleTypeNum]) / _busdTypeCurrentVaultHoldings[_busdCycleTypeNum];
        }
    }

    function depositDXFType(uint256 amount) external nonReentrant existBlackList(_msgSender())
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

    function depositBUSDType(uint256 amount) external nonReentrant existBlackList(_msgSender())
    {
	    require(amount > 0, "The amount to deposit cannot be zero");
        require(_busdTypeDepositEnableStatus == true, "You can not deposit for this period!");

        if (_busdTypeDepositEnableStatus == true){
            _vaultToken.safeTransferFrom(
                address(_msgSender()),
                address(this),
                amount
            );
            _busdDXFBoxes[_msgSender()] += amount;
            _busdRewardBoxes[_busdCycleTypeNum][_msgSender()] = 0;

            _busdTypeCurrentVaultHoldings[_busdCycleTypeNum] += amount;

            addBusdTypeUserList(_msgSender());
            recalculateBUSDReward();
        }

        uint256 diffDays = DateTimeLibrary.diffDays(_startBusdTypeAt, block.timestamp);
        if (diffDays > _busdTypeWithdrawablePeriod){
            _busdTypeDepositEnableStatus = false;
            _busdTypeWithdrawEnableStatus = false;
        } 

        emit Deposit("BUSDDepositBox", _msgSender(), amount);
    }

    function withdrawDXFType(bool isClaimAll) external nonReentrant existBlackList(_msgSender())
    {
        require(_dxfBoxes[_msgSender()].startTime != 0, "This address did not deposited yet.");
        
        DXFDepositBox storage tempBox = _dxfBoxes[_msgSender()];
        
        uint256 contractBalance = _vaultToken.balanceOf(address(this));
        require(
            contractBalance >= tempBox.principal,
            "Contract contains insufficient tokens to match this withdrawal attempt"
        );

        uint256 reward = calculateDXFTypeReward(_msgSender());
        uint256 feePercent = calculateDXFTypeFeePercent(_msgSender());

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

    function withdrawBUSDType(bool isClaimAll) external nonReentrant existBlackList(_msgSender())
    {
        require(_busdTypeWithdrawEnableStatus == true, "You can not withdraw for this period!");

        uint256 BUSDWithdrawAmount = 0;
        uint256 BUSDFeeToOwnerAmount = 0;
        uint256 index = 0;
        uint256 accountTotalReward = 0;

        for (index; index < _busdCycleTypeNum; index++)
        {
            if (_busdRewardBoxes[index][_msgSender()] != 0)
            {
                // TODO: Get BUSD token amount
                // uint256 contractBalance = _busdToken.balanceOf(address(this));
                // require(
                //     contractBalance >= _busdRewardBoxes[index][_msgSender()],
                //     "Contract contains insufficient tokens to match this withdrawal attempt"
                // );

                uint256 contractBalance = _vaultToken.balanceOf(address(this));
                require(
                    contractBalance >= _busdTypeCurrentBUSDAmount[index],
                    "Contract contains insufficient tokens to match this withdrawal attempt"
                );

                accountTotalReward += _busdRewardBoxes[index][_msgSender()];
                _busdTypeCurrentBUSDAmount[index] -= _busdRewardBoxes[index][_msgSender()];
            }

            BUSDWithdrawAmount = accountTotalReward * (_maxPercentage - _busdTypeBUSDFeePercentage) / _maxPercentage;
            BUSDFeeToOwnerAmount = accountTotalReward * _busdTypeBUSDFeePercentage / _maxPercentage;

            _vaultToken.safeTransfer(_msgSender(), BUSDWithdrawAmount);
            _vaultToken.safeTransfer(_lpAddress, BUSDFeeToOwnerAmount);
        }

        emit Withdrawal("BUSDDepositBox - BUSD", _msgSender(), BUSDWithdrawAmount);

	    if (isClaimAll)
        {
            uint256 contractBalance = _vaultToken.balanceOf(address(this));
            require(
                contractBalance >= _busdDXFBoxes[_msgSender()],
                "Contract contains insufficient tokens to match this withdrawal attempt"
            );

            uint256 DXFWithdrawAmount = 0;
            uint256 DXFFeeToOwnerAmount = 0;

            DXFWithdrawAmount = _busdDXFBoxes[_msgSender()] * (_maxPercentage - _busdTypeDXFFeePercentage) / _maxPercentage;
            DXFFeeToOwnerAmount = _busdDXFBoxes[_msgSender()] * _busdTypeDXFFeePercentage / _maxPercentage;

            _vaultToken.safeTransfer(_msgSender(), DXFWithdrawAmount);
            _vaultToken.safeTransfer(_reserveWalletAddress, DXFFeeToOwnerAmount);
            
            _busdDXFBoxes[_msgSender()] = 0;
            for (index = 0; index < _busdCycleTypeNum; index++)
            {
                if (_busdRewardBoxes[index][_msgSender()] != 0)
                {
                    delete _busdRewardBoxes[index][_msgSender()];
                }
            }
            
            recalculateBUSDReward();

            emit Withdrawal("BUSDDepositBox - DXF", _msgSender(), DXFWithdrawAmount);
        }
    }

    function withdrawDXFTypeEmergency(address receiveAccount) external onlyOwner
    {
        require(_dxfBoxes[_msgSender()].startTime != 0, "This address did not deposited yet.");
        
        DXFDepositBox storage tempBox = _dxfBoxes[_msgSender()];
        
        uint256 amount = tempBox.principal;

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

        emit EmergencyWithdrawal("DXFDepositBox", receiveAccount, amount);
    }

    function withdrawBUSDTypeEmergency(address receiveAccount) external onlyOwner
    {
        uint256 contractBalance = _vaultToken.balanceOf(address(this));
        require(
            contractBalance >= _busdDXFBoxes[_msgSender()],
            "Contract contains insufficient tokens to match this withdrawal attempt"
        );

        uint256 amount = _busdDXFBoxes[_msgSender()];

        _vaultToken.safeTransfer(receiveAccount, _busdDXFBoxes[_msgSender()]);

        _busdDXFBoxes[_msgSender()] = 0;
        
        uint256 index = 0;
        for (index; index < _busdCycleTypeNum; index++)
        {
            if (_busdRewardBoxes[index][_msgSender()] != 0)
            {
                delete _busdRewardBoxes[index][_msgSender()];
            }
        }
        
        recalculateBUSDReward();

        emit EmergencyWithdrawal("BUSDDepositBox - DXF", receiveAccount, amount);
    }

    function getCurrentDXFTypeInfo(address account) external existBlackList(account) view returns(uint256, uint256)
    {
        require(_dxfBoxes[account].startTime != 0, "This address did not deposited yet.");
        
        DXFDepositBox storage tempBox = _dxfBoxes[account];

        uint256 reward = calculateDXFTypeReward(account);
        uint256 feePercent = calculateDXFTypeFeePercent(account);
        uint256 feeForReward = ((reward - tempBox.lastWithdrawAmount) * feePercent / 1 gwei) / 100;

        uint256 principal = tempBox.principal;
        uint256 rewardRes = reward - tempBox.principal - feeForReward;
        
        return (principal, rewardRes);
    }

    function getCurrentBUSDTypeInfo(address account) external existBlackList(account) view returns(uint256, uint256)
    {
        uint256 BUSDWithdrawAmount = 0;
        uint256 index = 0;
        uint256 accountTotalReward = 0;

        for (index; index < _busdCycleTypeNum; index++)
        {
            if (_busdRewardBoxes[index][account] != 0)
            {
                accountTotalReward += _busdRewardBoxes[index][account];
            }

            BUSDWithdrawAmount = accountTotalReward * (_maxPercentage - _busdTypeBUSDFeePercentage) / _maxPercentage;
        }

        return (_busdDXFBoxes[account], BUSDWithdrawAmount);
    }

    function setDXFTypeFeeInitPercentage(uint256 percentage) external onlyOwner
    {
        require(percentage > 0, "The initialization percentage cannot be zero");
        _dxfTypeFeeInitPercentage = percentage;  
    }

    function setDXFTypeFeeRatePerMonth(uint256 rate) external onlyOwner
    {
        require(rate > 0, "The rate cannot be zero");
        _dxfTypeFeeRatePerMonth = rate;    
    }

    function setDXFTypeFeeMinPercentage(uint256 minPercentage) external onlyOwner
    {
        require(minPercentage > 0, "The minimum percentage cannot be zero");
        _dxfTypeFeeMinPercentage = minPercentage;   
    }

    function setDXFTypeRewardInitPercentage(uint256 percentage) external onlyOwner
    {
        require(percentage > 0, "The initialization percentage cannot be zero");
        _dxfTypeRewardInitPercentage = percentage;
    }

    function setDXFTypeRewardRatePerMonth(uint256 rate) external onlyOwner
    {
        require(rate > 0, "The rate cannot be zero");
        _dxfTypeRewardRatePerMonth = rate; 
    }

    function setDXFTypeRewardMaxPercentage(uint256 maxPercentage) external onlyOwner
    {
        require(maxPercentage > 0, "The maximum percentage cannot be zero");
        _dxfTypeRewardMaxPercentage = maxPercentage; 
    }

    function setBUSDTypeDXFFeePercentage(uint256 percentage) external onlyOwner
    {
        require(percentage > 0, "The maximum percentage cannot be zero");
        _busdTypeDXFFeePercentage = percentage;
    }

    function setBUSDTypeBUSDFeePercentage(uint256 percentage) external onlyOwner
    {
        require(percentage > 0, "The maximum percentage cannot be zero");
        _busdTypeBUSDFeePercentage = percentage;
    }

    function startBUSDType() public onlyOwner
    {
        _startBusdTypeAt = block.timestamp;
        _busdTypeDepositEnableStatus = true;
    }

    // Only onwer can call this function emergency
    function stopBUSDType() public onlyOwner
    {
        _stopBusdTypeAt = block.timestamp;
        uint256 diffDays = DateTimeLibrary.diffDays(_startBusdTypeAt, _stopBusdTypeAt);
        if (diffDays == 120)
        {
            _busdTypeWithdrawEnableStatus = true;

            if (_busdTypeAutoStart)
            {
                startBUSDType();
            }
        }
    }

    function setAutoStartBUSDType(bool isAuto) external onlyOwner 
    {
        _busdTypeAutoStart = isAuto;
    }

    function getBUSDInType() public view returns (uint256 amount)
    {
        return _busdTypeCurrentBUSDAmount[_busdCycleTypeNum];
    }

    function putBUSDInType(uint256 amount) external onlyOwner
    {
        require(amount > 0, "BUSD amount must be greate than 0!");
        _busdTypeCurrentBUSDAmount[_busdCycleTypeNum] = amount;
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