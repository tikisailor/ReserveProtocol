// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../../libraries/Fixed.sol";
import "./AbstractCollateral.sol";
import "./IrEARN.sol";

/**
 * @title RibbonEarnUsdcCollateral
 * @notice Collateral plugin for the Ribbon Earn USDC Vault
 * Expected: {tok} == rEARN, {ref} == USDC, {target} == USD, 
 * {ref} is pegged to {target} or defaults, {target} == {UoA}
 */
contract RibbonEarnUsdcCollateral is Collateral {
    using FixLib for uint192;
    using OracleLib for AggregatorV3Interface;

    uint192 public immutable defaultThreshold; // {%} e.g. 0.05

    uint192 public prevReferencePrice; // previous rate, {collateral/reference}

    /// @param maxTradeVolume_ {UoA} The max trade volume, in UoA
    /// @param maxTradeVolume_ {UoA} The max trade volume, in UoA
    /// @param oracleTimeout_ {s} The number of seconds until a oracle value becomes invalid
    /// @param delayUntilDefault_ {s} The number of seconds deviation must occur before default

    constructor(
        uint192 fallbackPrice_,
        AggregatorV3Interface chainlinkFeed_,
        IERC20Metadata erc20_,
        uint192 maxTradeVolume_,
        uint48 oracleTimeout_,
        bytes32 targetName_,
        uint256 delayUntilDefault_,
        uint192 defaultThreshold_
    )
        Collateral(
            fallbackPrice_,
            chainlinkFeed_,
            erc20_,
            maxTradeVolume_,
            oracleTimeout_,
            targetName_,
            delayUntilDefault_
        )
    {
        require(defaultThreshold_ > 0, "defaultThreshold zero");
        defaultThreshold = defaultThreshold_;
    }

    /// Refresh exchange rates and update default status.
    /// @dev This default check assumes that the collateral's price() value is expected
    /// to stay close to pricePerTarget() * targetPerRef(). If that's not true for the
    /// collateral you're defining, you MUST redefine refresh()!!
    function refresh() external virtual override {
        if (alreadyDefaulted()) return;
        CollateralStatus oldStatus = status();

        // Check for hard default
        uint192 referencePrice = refPerTok();
        // uint192(<) is equivalent to Fix.lt
        if (referencePrice < prevReferencePrice) {
            markStatus(CollateralStatus.DISABLED);
        } else {
            try chainlinkFeed.price_(oracleTimeout) returns (uint192 p) {
                // Check for soft default of underlying reference token
                // D18{UoA/ref} = D18{UoA/target} * D18{target/ref} / D18
                uint192 peg = (pricePerTarget() * targetPerRef()) / FIX_ONE;

                // D18{UoA/ref}= D18{UoA/ref} * D18{1} / D18
                uint192 delta = (peg * defaultThreshold) / FIX_ONE; // D18{UoA/ref}

                // If the price is below the default-threshold price, default eventually
                // uint192(+/-) is the same as Fix.plus/minus
                if (p < peg - delta || p > peg + delta) {

                        // since refernce is usdc we can use usdc depeg
                        markStatus(CollateralStatus.IFFY);
                }
                else {
                    markStatus(CollateralStatus.SOUND);
                }
            } catch (bytes memory errData) {
                // see: docs/solidity-style.md#Catching-Empty-Data
                if (errData.length == 0) revert(); // solhint-disable-line reason-string

                    markStatus(CollateralStatus.IFFY);
            }
        }
        prevReferencePrice = referencePrice;

        CollateralStatus newStatus = status();
        if (oldStatus != newStatus) {
            emit CollateralStatusChanged(oldStatus, newStatus);
        }
    }

    
    /// @return {ref/tok} Quantity of whole reference units per whole collateral tokens
    /// rEARN had 6 decimals
    function refPerTok() public view override returns (uint192) {
        uint256 pricePerShare = IrEARN(address(erc20)).pricePerShare();
        int8 shiftLeft = -6;
        return shiftl_toFix(pricePerShare, shiftLeft);
    }

    /// Can return 0, can revert
    /// @return {UoA/tok} The current price()
    /// we cancel out ref to get {UoA/tok}
    function strictPrice() public view override returns (uint192) {
        uint192 refPerUoa = chainlinkFeed.price(oracleTimeout); // usdc/usd
        return refPerUoa.mul(refPerTok());
    }

    /// Can return 0
    /// Cannot revert if `allowFallback` is true. Can revert if false.
    /// @param allowFallback Whether to try the fallback price in case precise price reverts
    /// @return isFallback If the price is a allowFallback price
    /// @return {UoA/tok} The current price, or if it's reverting, a fallback price
    function price(bool allowFallback) public view virtual returns (bool isFallback, uint192) {
        try this.strictPrice() returns (uint192 p) {
            return (false, p);
        } catch {
            require(allowFallback, "price reverted without failover enabled");
            return (true, fallbackPrice.mul(refPerTok()));
        }
    }
}