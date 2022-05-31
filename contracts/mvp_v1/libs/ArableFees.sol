// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library ArableFees {
    enum Model {
        DEFAULT,           // default fees if asset is unknow (0)
        SETUP_FARM,        // new farm fees
        EXIT_FARM,         // exit farm fees
        REWARD,            // reward fees
        SYNTHS_X,          // synthetic asset exchange fees
        SYNTHS_MINT,       // synthetic asset mint fees
        SYNTHS_BURN,       // synthetic asset burn fees
        LIQUIDATE,         // liquidation fees
        MAX                // maximumn value (8)
    }
}
