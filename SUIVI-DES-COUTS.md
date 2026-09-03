# Suivi des coûts

Tous les comptes sont en **prépayé sans renouvellement automatique** : aucun
prélèvement ne peut survenir sans une action explicite. Le pire scénario est
l'arrêt du service, pas un dépassement.

Aucun fournisseur ne facture en euros — la conversion se fait au prélèvement.

## Ce qui consomme du crédit

| Service | Tableau de bord | À regarder | Ordre de grandeur |
|---|---|---|---|
| **DeepSeek** | https://platform.deepseek.com | Usage / Balance | Poste principal, mais quelques centimes par mois à deux |
| **OpenAI** | https://platform.openai.com/usage | Graphique + « Credit balance » sur l'accueil | Embeddings négligeables ; images ~0,05 $ pièce |
| **Tavily** | https://app.tavily.com | Usage | 1 crédit ≈ 1 recherche, quota mensuel remis à zéro |

## Paliers gratuits à surveiller de loin

| Service | Tableau de bord | Seuil |
|---|---|---|
| Cloudflare R2 | https://dash.cloudflare.com → R2 → Metrics | 10 Go de stockage |
| Neon | https://console.neon.tech → projet → Usage | 0,5 Go de base, 100 h de calcul |
| Vercel | https://vercel.com → projet → Usage | Bande passante, invocations |

À deux utilisateurs, ces trois postes restent sous 1 % de leur palier.

## Rythme conseillé

Une fois par semaine le premier mois, le temps de mesurer la vitesse réelle de
consommation. Une fois par mois ensuite.

Le seul chiffre qui compte vraiment est le solde DeepSeek : s'il n'a pas bougé
au bout d'un mois, le sujet peut être oublié.

## Ce qui fait vraiment varier la facture

- **La longueur des conversations.** Tout l'historique est renvoyé à chaque
  message. DeepSeek facture la relecture d'un préfixe déjà vu 30 fois moins
  cher (0,05 contre 1,5 CNY / M tokens), ce qui rend une conversation
  poursuivie **environ 5 fois moins chère** que ne le laisserait croire un
  calcul au tarif plein. Poursuivre un fil est donc économiquement bon.
- **Le nombre d'images par requête.** `AI_IMAGE_DEFAULT_IMAGE_NUM=1` est posée :
  sans elle LobeChat en génère 4 par demande, soit 4 fois le prix.
- **Le modèle choisi.** DeepSeek V4 Pro coûte 3 fois V4 Flash. Pour les images,
  GPT Image 1 Mini coûte 5 fois moins que GPT Image 2.
