#!/usr/bin/env bash
#
# Run a minimal Solana cluster.  Ctrl-C to exit.
#
# Before running this script ensure standard Solana programs are available
# in the PATH, or that `cargo build` ran successfully
#
set -e

# Prefer possible `cargo build` binaries over PATH binaries
cd "$(dirname "$0")/"

profile=debug
if [[ -n $NDEBUG ]]; then
    profile=release
fi
PATH=$PWD/target/$profile:$PATH

ok=true
for program in velas-{faucet,genesis,keygen,validator}; do
    $program -V || ok=false
done
$ok || {
    echo
    echo "Unable to locate required programs.  Try building them first with:"
    echo
    echo "  $ cargo build --all"
    echo
    exit 1
}

export RUST_LOG=${RUST_LOG:-solana=info,solana_runtime::message_processor=debug} # if RUST_LOG is unset, default to info
export RUST_BACKTRACE=1
dataDir=$PWD/config/"$(basename "$0" .sh)"
ledgerDir=$PWD/config/ledger

SOLANA_RUN_SH_CLUSTER_TYPE=${SOLANA_RUN_SH_CLUSTER_TYPE:-development}

set -x
if ! velas address; then
    echo Generating default keypair
    velas-keygen new --no-passphrase
fi
validator_identity="$dataDir/validator-identity.json"
if [[ -e $validator_identity ]]; then
    echo "Use existing validator keypair"
else
    velas-keygen new --no-passphrase -so "$validator_identity"
fi
validator_vote_account="$dataDir/validator-vote-account.json"
if [[ -e $validator_vote_account ]]; then
    echo "Use existing validator vote account keypair"
else
    velas-keygen new --no-passphrase -so "$validator_vote_account"
fi
validator_stake_account="$dataDir/validator-stake-account.json"
if [[ -e $validator_stake_account ]]; then
    echo "Use existing validator stake account keypair"
else
    velas-keygen new --no-passphrase -so "$validator_stake_account"
fi

if [[ -e "$ledgerDir"/genesis.bin || -e "$ledgerDir"/genesis.tar.bz2 ]]; then
    echo "Use existing genesis"
else
    ./fetch-spl.sh
    if [[ -r spl-genesis-args.sh ]]; then
        SPL_GENESIS_ARGS=$(cat spl-genesis-args.sh)
    fi
    
    # shellcheck disable=SC2086
    velas-genesis \
    --hashes-per-tick sleep \
    --faucet-lamports 500000000000000000 \
    --bootstrap-validator \
      "$validator_identity" \
      "$validator_vote_account" \
      "$validator_stake_account" \
    --ledger "$ledgerDir" \
    --cluster-type "$SOLANA_RUN_SH_CLUSTER_TYPE" \
    $SPL_GENESIS_ARGS \
    --max-genesis-archive-unpacked-size=300000000 \
    $SOLANA_RUN_SH_GENESIS_ARGS
    # --evm-root="0x7b343e0165c8f354ac7b1e7e7889389f42927ccb9d0330b3036fb749e12795ba" \
    # --evm-state-file="../state.json" \
    # --evm-chain-id 111\
fi

abort() {
    set +e
    kill "$faucet" "$validator"
    wait "$validator"
}
trap abort INT TERM EXIT

velas-faucet &
faucet=$!

args=(
    --identity "$dataDir"/validator-identity.json
    --vote-account "$dataDir"/validator-vote-account.json
    --ledger "$ledgerDir"
    --gossip-port 8001
    --rpc-port 8899
    --rpc-faucet-address 127.0.0.1:9900
    --log -
    --enable-rpc-transaction-history
    --enable-cpi-and-log-storage
    --init-complete-file "$dataDir"/init-completed
    --snapshot-compression none
    --accounts-db-caching-enabled
    --snapshot-interval-slots 100
    --require-tower
    --no-wait-for-vote-to-start-leader
    --account-index program-id
    --account-index spl-token-owner
    --account-index spl-token-mint
    --account-index velas-accounts-storages
    --account-index velas-accounts-owners
    --account-index velas-accounts-operationals
)
# shellcheck disable=SC2086
velas-validator "${args[@]}" $SOLANA_RUN_SH_VALIDATOR_ARGS &
validator=$!

wait "$validator"
