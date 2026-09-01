#!/usr/bin/env node
/**
 * Génère la paire de clés RSA RS256 au format JWKS attendue par LobeChat
 * dans la variable d'environnement JWKS_KEY.
 *
 * Équivalent sans dépendance du `scripts/generate-oidc-jwk.mjs` de l'amont
 * (qui exige le paquet `jose`) : ici tout passe par node:crypto, donc le
 * script tourne sans `npm install`.
 *
 * Sort le JWKS sur une seule ligne, prêt à coller dans Vercel.
 */
import crypto from 'node:crypto';

const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });

const jwk = privateKey.export({ format: 'jwk' });

jwk.use = 'sig';
jwk.kid = crypto.randomBytes(8).toString('hex');
jwk.alg = 'RS256';

console.log(JSON.stringify({ keys: [jwk] }));
