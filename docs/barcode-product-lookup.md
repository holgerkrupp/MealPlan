# Optional barcode product lookup

Meals keeps barcode adding useful without a network connection. `BarcodeProductMemory`
always wins: a name the person has entered for a barcode is used immediately and
is never replaced by a public suggestion. Unknown barcodes can optionally use
the Open Food Facts read API from the barcode sheet. The suggestion is editable,
and saving it to the pantry or shopping list teaches the on-device memory.

## Privacy and operating limits

- The request contains the normalized barcode only. Meals does not send
  household, account, recipe, location, or shopping-list information.
- Lookup is off by default and can be enabled from the barcode sheet. No
  credentials, paid service, or Meals server is required.
- Successful and unknown results are held in a bounded in-memory cache of 128
  barcode outcomes for up to 30 days. Temporary offline and service failures
  are not cached, so retrying after connectivity returns works immediately.
- Requests are deduplicated by normalized barcode, use an ephemeral URL
  session, carry a descriptive `User-Agent`, and time out after eight seconds
  (ten seconds for the whole resource). Leaving the sheet cancels the request.
- The UI distinguishes found, unknown, offline, failed, and cancelled outcomes;
  every non-found state leaves the editable manual name field available.

## Open Food Facts decision

Open Food Facts was selected because its barcode read endpoint is public and
does not require an embedded secret. The client uses the documented v3.6
product endpoint and requests only the fields needed for a display suggestion.
Open Food Facts documents a read limit of 15 product requests per minute per IP
and asks clients to identify themselves with a custom `User-Agent`; the local
cache, request coalescing, and opt-in flow keep Meals well below that limit in
normal use. Product data is open data under the Open Database License (ODbL),
so the barcode sheet links to Open Food Facts and names it as the data source.

Sources (reviewed 2026-11-24):

- [Open Food Facts API introduction](https://openfoodfacts.github.io/documentation/docs/Product-Opener/api/)
- [Open Food Facts barcode lookup](https://openfoodfacts.github.io/documentation/docs/Product-Opener/api/tutorials/scanning-barcodes/)
- [Open Food Facts API and data reuse conditions](https://support.openfoodfacts.org/help/en-gb/12-api-data-reuse/94-are-there-conditions-to-use-the-api)

