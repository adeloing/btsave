/**
 * Keeper Test Script — Phase 1
 * Proposes a test transaction to the Module on Sepolia.
 */

const { ethers } = require('ethers');
const fs = require('fs');

const RPC_URL = process.env.RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com';
const PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const MODULE_ADDRESS = '0x40f7b06433f27B9C9C24fD5d60F2816F9344e04E';
const TARGET_ADDRESS = '0xC5D4397049AE8BfD7f59B37ee31169d4B8D18DfC';

const MODULE_ABI = JSON.parse(fs.readFileSync(__dirname + '/module-abi.json', 'utf8'));

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const module = new ethers.Contract(MODULE_ADDRESS, MODULE_ABI, wallet);

  console.log(`🔑 Keeper: ${wallet.address}`);
  console.log(`📍 Module: ${MODULE_ADDRESS}`);
  console.log(`🎯 Target: ${TARGET_ADDRESS}\n`);

  // Encode target function call: doSomething(42)
  const targetIface = new ethers.Interface(['function doSomething(uint256 v)']);
  const calldata = targetIface.encodeFunctionData('doSomething', [42]);

  console.log(`📤 Proposing tx: doSomething(42)`);
  console.log(`   Calldata: ${calldata}`);

  try {
    const tx = await module.proposeTransaction(TARGET_ADDRESS, calldata, 0);
    console.log(`   Tx hash: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log(`   ✅ Mined in block ${receipt.blockNumber}`);

    // Decode TxProposed event
    for (const log of receipt.logs) {
      try {
        const parsed = module.interface.parseLog(log);
        if (parsed && parsed.name === 'TxProposed') {
          console.log(`\n📋 TxProposed event:`);
          console.log(`   Proposal hash: ${parsed.args[0]}`);
          console.log(`   Keeper: ${parsed.args[1]}`);
          console.log(`   Target: ${parsed.args[2]}`);
          console.log(`   Selector: ${parsed.args[3]}`);
        }
      } catch {}
    }
  } catch (err) {
    console.error(`❌ Error: ${err.reason || err.message}`);
  }
}

main().catch(console.error);
