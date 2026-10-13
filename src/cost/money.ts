// Decimal arithmetic for pricing (ADR-0011 decision 8). A private decimal.js
// constructor with 60 significant digits keeps sums exact for these inputs:
// token counts are integers below 2^53, rates carry a few decimal places, and
// the only divisions are by the rate card's token unit and by the CCU
// definition, both powers of ten. The library's default of 20 significant
// digits could round a large sum of small amounts. Nothing here rounds for
// presentation; that happens once, where a figure is displayed.

import { Decimal } from "decimal.js";

export const Money = Decimal.clone({ precision: 60, rounding: Decimal.ROUND_HALF_UP });
