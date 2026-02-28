/**
 * Keeper Test Script — Phase 1
 * Proposes a test transaction to the Module on Sepolia.
 */

const { ethers } = require('ethers');
const fs = require('fs');

const RPC_URL = process.env.RPC_URL || 'https://0xrpc.io/sep';
const PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
const MODULE_ADDRESS = '0x0e81f9cDE815709A73e609F7424B1Fa0FF7dc153';
const TARGET_ADDRESS = '0x77b819DD5B8E441f11CeF25421A111c0AD0003b5';

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
