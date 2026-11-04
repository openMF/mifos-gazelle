// Register the demo payees in the vNext ALS built-in oracle.
//
// The switch resolves a party from account-lookup.builtinOracleParties. The FSPIOP
// _interop admin API writes to the HTTP oracle instead, which the ALS does not read for
// these parties, so the entries are written here directly.
//
// Run with mongosh inside the mongodb pod. Input arrives in environment variables:
//   PAYEES  MSISDN separated by spaces, e.g. "0495700001 0495700002"
//   FSP_ID  the payee bank that owns them, e.g. bluebank

const payees = process.env.PAYEES.trim().split(/\s+/);
const fspId = process.env.FSP_ID;

payees.forEach(function (partyId) {
    db.builtinOracleParties.updateOne(
        { partyId: partyId, partyType: "MSISDN" },
        { $set: { partyId: partyId, partyType: "MSISDN", fspId: fspId, currency: "USD" } },
        { upsert: true }
    );
});

print("  builtinOracleParties agri count: " +
      db.builtinOracleParties.countDocuments({ partyId: { $in: payees } }));
