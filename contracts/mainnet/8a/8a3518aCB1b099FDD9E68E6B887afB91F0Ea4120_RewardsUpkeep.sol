// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../../interfaces/investments/frax-gauge/temple-frax/ILiquidityOps.sol";
import "../../../interfaces/investments/frax-gauge/temple-frax/IRewardsManager.sol";
import "../../../interfaces/investments/frax-gauge/tranche/ITranche.sol";
import "../../../interfaces/external/chainlink/IKeeperCompatibleInterface.sol";

interface IOldLiquidityOps {
    function getReward() external returns (uint256[] memory data);
    function harvestRewards() external;
}

/// @notice A Chainlink Keeper contract which can automate collection & distribution of
///         rewards on a periodic basis
contract RewardsUpkeep is IKeeperCompatibleInterface, Ownable {
    // Rewards manager contract address
    IRewardsManager public rewardsManager;

    // Liquidity ops contract address
    ILiquidityOps public liquidityOps;

    // The old liquidity ops contract - we need to harvest rewards
    // from here until the TVL is migrated into the new one.
    IOldLiquidityOps public oldLiquidityOps;

    // Time interval between distributions
    uint256 public interval;

    // Last distribution time
    uint256 public lastTimeStamp;

    // The list of reward token addresses to distribute.
    // This may be direct gauge rewards, and also extra protocol rewards.
    address[] public rewardTokens;

    event IntervalSet(uint256 _interval);
    event RewardsManagerSet(address _rewardsManager);
    event LiquidityOpsSet(address _liquidityOps);
    event OldLiquidityOpsSet(address _liquidityOps);
    event UpkeepPerformed(uint256 lastTimeStamp);
    event RewardTokensSet(address[] _rewardTokens);

    error NotLongEnough(uint256 minExpected);

    constructor(
        uint256 _updateInterval,
        address _rewardsManager,
        address _liquidityOps
    ) {
        interval = _updateInterval;
        rewardsManager = IRewardsManager(_rewardsManager);
        liquidityOps = ILiquidityOps(_liquidityOps);
    }

    function setInterval(uint256 _interval) external onlyOwner {
        if (_interval < 3600) revert NotLongEnough(3600);
        interval = _interval;

        emit IntervalSet(_interval);
    }

    function setRewardsManager(address _rewardsManager) external onlyOwner {
        rewardsManager = IRewardsManager(_rewardsManager);

        emit RewardsManagerSet(_rewardsManager);
    }

    function setLiquidityOps(address _liquidityOps) external onlyOwner {
        liquidityOps = ILiquidityOps(_liquidityOps);

        emit LiquidityOpsSet(_liquidityOps);
    }

    function setOldLiquidityOps(address _oldLiquidityOps) external onlyOwner {
        oldLiquidityOps = IOldLiquidityOps(_oldLiquidityOps);

        emit OldLiquidityOpsSet(_oldLiquidityOps);
    }

    function setRewardTokens(address[] memory _rewardTokens) external onlyOwner {
        rewardTokens = _rewardTokens;

        emit RewardTokensSet(_rewardTokens);
    }

    // Called by Chainlink Keepers to check if upkeep should be executed
    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp - lastTimeStamp) > interval;
        address[] memory tranches = liquidityOps.allTranches();

        // First get the number of active tranches, to create the fixed size array
        uint256 numActive;
        for (uint256 i=0; i<tranches.length; i++) {
            if (!ITranche(tranches[i]).disabled()) {
                numActive++;
            }
        }

        // Now create and fill the activeTranches
        uint256 index;
        address[] memory activeTranches = new address[](numActive);
        for (uint256 i=0; i<tranches.length; i++) {
            if (!ITranche(tranches[i]).disabled()) {
                activeTranches[index] = tranches[i];
                index++;
            }
        }

        performData = abi.encode(activeTranches);
    }

    // Called by Chainlink Keepers to distribute rewards
    function performUpkeep(bytes calldata performData) external override {
        if ((block.timestamp - lastTimeStamp) <= interval) revert NotLongEnough(interval);
        (address[] memory activeTranches) = abi.decode(performData, (address[]));

        // Claim and harvest the underlying rewards
        liquidityOps.getRewards(activeTranches);
        liquidityOps.harvestRewards();

        // Support harvesting from the old liquidity ops and sending to the 
        // current rewards manager.
        // Rewards from both the old and the current liquidity ops are harvested
        // to the same rewards manager.
        if (address(oldLiquidityOps) != address(0)) {
            oldLiquidityOps.getReward();
            oldLiquidityOps.harvestRewards();
        }

        // Loop through and distribute reward tokens
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 rewardBalance = IERC20(rewardTokens[i]).balanceOf(address(rewardsManager));
            if (rewardBalance > 0) {
                rewardsManager.distribute(rewardTokens[i]);
            }
        }

        lastTimeStamp = block.timestamp;
        emit UpkeepPerformed(lastTimeStamp);
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (access/Ownable.sol)

pragma solidity ^0.8.0;

import "../utils/Context.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

pragma solidity ^0.8.4;
// SPDX-License-Identifier: AGPL-3.0-or-later
// STAX (interfaces/investments/frax-gauge/temple-frax/ILiquidityOps.sol)

interface ILiquidityOps {
    function allTranches() external view returns (address[] memory);
    function getRewards(address[] calldata _tranches) external;
    function harvestRewards() external;
    function minCurveLiquidityAmountOut(
        uint256 _liquidity,
        uint256 _modelSlippage
    ) external view returns (uint256 minCurveTokenAmount);
    function applyLiquidity(uint256 _liquidity, uint256 _minCurveTokenAmount) external;
}

pragma solidity ^0.8.4;
// SPDX-License-Identifier: AGPL-3.0-or-later
// STAX (interfaces/investments/frax-gauge/temple-frax/IRewardsManager.sol)

interface IRewardsManager {
    function distribute(address _token) external;
}

pragma solidity ^0.8.4;
// SPDX-License-Identifier: AGPL-3.0-or-later
// STAX (interfaces/investments/frax-gauge/tranche/ITranche.sol)

import "../../../external/frax/IFraxGauge.sol";

interface ITranche {
    enum TrancheType {
        DIRECT,
        CONVEX_VAULT
    }

    event RegistrySet(address indexed registry);
    event SetDisabled(bool isDisabled);
    event RewardClaimed(address indexed trancheAddress, uint256[] rewardData);
    event AdditionalLocked(address indexed staker, bytes32 kekId, uint256 liquidity);
    event VeFXSProxySet(address indexed proxy);
    event MigratorToggled(address indexed migrator);

    error InactiveTranche(address tranche);
    error AlreadyInitialized();
    
    function disabled() external view returns (bool);
    function willAcceptLock(uint256 liquidity) external view returns (bool);
    function lockedStakes() external view returns (IFraxGauge.LockedStake[] memory);

    function initialize(address _registry, uint256 _fromImplId, address _newOwner) external returns (address, address);
    function setRegistry(address _registry) external;
    function setDisabled(bool isDisabled) external;
    function setVeFXSProxy(address _proxy) external;
    function toggleMigrator(address migrator_address) external;

    function stake(uint256 liquidity, uint256 secs) external returns (bytes32 kek_id);
    function withdraw(bytes32 kek_id, address destination_address) external returns (uint256 withdrawnAmount);
    function getRewards(address[] calldata rewardTokens) external returns (uint256[] memory rewardAmounts);
}

pragma solidity ^0.8.4;
// SPDX-License-Identifier: AGPL-3.0-or-later
// STAX (interfaces/external/chainlink/IKeeperCompatibleInterface.sol)

interface IKeeperCompatibleInterface {
    /**
     * @notice method that is simulated by the keepers to see if any work actually
     * needs to be performed. This method does does not actually need to be
     * executable, and since it is only ever simulated it can consume lots of gas.
     * @dev To ensure that it is never called, you may want to add the
     * cannotExecute modifier from KeeperBase to your implementation of this
     * method.
     * @param checkData specified in the upkeep registration so it is always the
     * same for a registered upkeep. This can easily be broken down into specific
     * arguments using `abi.decode`, so multiple upkeeps can be registered on the
     * same contract and easily differentiated by the contract.
     * @return upkeepNeeded boolean to indicate whether the keeper should call
     * performUpkeep or not.
     * @return performData bytes that the keeper should call performUpkeep with, if
     * upkeep is needed. If you would like to encode data to decode later, try
     * `abi.encode`.
     */
    function checkUpkeep(bytes calldata checkData)
        external
        returns (bool upkeepNeeded, bytes memory performData);

    /**
     * @notice method that is actually executed by the keepers, via the registry.
     * The data returned by the checkUpkeep simulation will be passed into
     * this method to actually be executed.
     * @dev The input to this method should not be trusted, and the caller of the
     * method should not even be restricted to any single registry. Anyone should
     * be able call it, and the input should be validated, there is no guarantee
     * that the data passed in is the performData returned from checkUpkeep. This
     * could happen due to malicious keepers, racing keepers, or simply a state
     * change while the performUpkeep transaction is waiting for confirmation.
     * Always validate the data passed in.
     * @param performData is the data which was passed back from the checkData
     * simulation. If it is encoded, it can easily be decoded into other types by
     * calling `abi.decode`. This data should not be trusted, and should be
     * validated against the contract's current state.
     */
    function performUpkeep(bytes calldata performData) external;
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (utils/Context.sol)

pragma solidity ^0.8.0;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

pragma solidity ^0.8.4;
// SPDX-License-Identifier: AGPL-3.0-or-later
// STAX (interfaces/external/curve/IFraxGauge.sol)

// ref: https://github.com/FraxFinance/frax-solidity/blob/master/src/hardhat/contracts/Staking/FraxUnifiedFarm_ERC20.sol

interface IFraxGauge {
    struct LockedStake {
        bytes32 kek_id;
        uint256 start_timestamp;
        uint256 liquidity;
        uint256 ending_timestamp;
        uint256 lock_multiplier; // 6 decimals of precision. 1x = 1000000
    }

    function stakeLocked(uint256 liquidity, uint256 secs) external;
    function lockAdditional(bytes32 kek_id, uint256 addl_liq) external;
    function withdrawLocked(bytes32 kek_id, address destination_address) external;

    function lockedStakesOf(address account) external view returns (LockedStake[] memory);
    function getAllRewardTokens() external view returns (address[] memory);
    function getReward(address destination_address) external returns (uint256[] memory);

    function stakerSetVeFXSProxy(address proxy_address) external;
    function stakerToggleMigrator(address migrator_address) external;

    function lock_time_min() external view returns (uint256);
    function lock_time_for_max_multiplier() external view returns (uint256);
}