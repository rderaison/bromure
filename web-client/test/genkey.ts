import fs from 'node:fs';
import { generateClientKey, openSSHPublicLine } from '../src/core/ssh/keys';
const [jwkOut, pubOut] = process.argv.slice(2);
const k = await generateClientKey(true);
fs.writeFileSync(jwkOut, JSON.stringify(await crypto.subtle.exportKey('jwk', k.privateKey)));
fs.writeFileSync(pubOut, openSSHPublicLine(k.publicRaw, 'bromure-web-test') + '\n');
console.log(fs.readFileSync(pubOut, 'utf8'));
