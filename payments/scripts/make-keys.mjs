#!/usr/bin/env node
// Makes the license signing keys. The private half goes to the server (LICENSE_SIGNING_KEY, keep it
// secret); the public half goes in the iPhone app (AW_PAYMENTS_PUBLIC_KEY in iPhoneRemote/project.yml).
//
//   node scripts/make-keys.mjs
import { makeSigningKeys } from "../lib/license.js";

const { signingKey, appPublicKey } = makeSigningKeys();
console.log("# Server (Vercel env var, secret):");
console.log(`LICENSE_SIGNING_KEY=${signingKey}`);
console.log("\n# iPhone app (iPhoneRemote/project.yml, public):");
console.log(`AW_PAYMENTS_PUBLIC_KEY: "${appPublicKey}"`);
