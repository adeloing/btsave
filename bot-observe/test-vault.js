const { ethers } = require('ethers');
// DEPLOYER_PRIVATE_KEY passed via env

const RPC = 'https://ethereum-sepolia-rpc.publicnode.com';
const VAULT = '0x3Da4D2fb92D6cF7D3eF66C78eBf380DBBFb2df71';
const USDC = '0x75dd7ad0dc2a6c1d877df6fb26686fb8f79ae98d';
const WBTC = '0xB976bD34beA832C126F53ab761bE4265AB714089';

const ERC20_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function decimals() view returns (uint8)'
];

const VAULT_ABI = [
  'function deposit(uint256) external',
  'function setAutoRedeemAtNextATH(uint256) external',
  'function balanceOf(address) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function getNav() view returns (uint256)',
  'function getNavPerShare() view returns (uint256)',
  'function getCycleInfo() view returns (uint256,uint256,uint256,bool,bool,bool)',
  'function getUserInfo(address) view returns (uint256,uint256,uint256,uint256)',
  'function autoRedeemPct(address) view returns (uint256)',
  'function isNFTEligible(address) view returns (bool)',
  'function getAutoRedeemStats() view returns (uint256,uint256)',
  'function pendingPoolBalance() view returns (uint256)'
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
  const addr = wallet.address;

  const usdc = new ethers.Contract(USDC, ERC20_ABI, wallet);
  const vault = new ethers.Contract(VAULT, VAULT_ABI, wallet);

  console.log(`\n🔑 Deployer: ${addr}`);
  console.log(`📍 Vault: ${VAULT}`);

  const step = process.argv[2] || 'all';

  if (step === 'all' || step === 'deposit') {
    console.log('\n=== TEST 3: Deposit 100 USDC ===');
    const balBefore = await vault.balanceOf(addr);
    console.log(`   TPB before: ${ethers.formatUnits(balBefore, 18)}`);

    const tx1 = await usdc.approve(VAULT, ethers.parseUnits('100', 6));
    await tx1.wait();
    console.log('   ✅ USDC approved');

    const tx2 = await vault.deposit(ethers.parseUnits('100', 6));
    const receipt = await tx2.wait();
    console.log(`   ✅ Deposit tx: ${receipt.hash}`);

    const balAfter = await vault.balanceOf(addr);
    console.log(`   TPB after: ${ethers.formatUnits(balAfter, 18)}`);
    console.log(`   TPB minted: ${ethers.formatUnits(balAfter - balBefore, 18)}`);

    const nav = await vault.getNav();
    console.log(`   NAV: ${ethers.formatUnits(nav, 6)} USDC`);
    const pending = await vault.pendingPoolBalance();
    console.log(`   Pending pool: ${ethers.formatUnits(pending, 6)} USDC`);
  }

  if (step === 'all' || step === 'autoredeem') {
    console.log('\n=== TEST 4: Set Auto-Redeem 50% ===');
    const tx3 = await vault.setAutoRedeemAtNextATH(50);
    await tx3.wait();
    const pct = await vault.autoRedeemPct(addr);
    console.log(`   ✅ Auto-Redeem set to ${pct}%`);
    const [users, demandBps] = await vault.getAutoRedeemStats();
    console.log(`   Registry: ${users} users, demand ${demandBps} BPS`);
  }

  if (step === 'all' || step === 'status') {
    console.log('\n=== STATUS ===');
    const [cycle, ath, start, active, redemption, unwind] = await vault.getCycleInfo();
    console.log(`   Cycle: ${cycle}, ATH: $${ethers.formatUnits(ath, 8)}, Active: ${active}`);
    const [bal, redeem, share, usdcVal] = await vault.getUserInfo(addr);
    console.log(`   Balance: ${ethers.formatUnits(bal, 18)} TPB`);
    console.log(`   Auto-Redeem: ${redeem}%`);
    console.log(`   Time-weighted share: ${share} BPS`);
    console.log(`   Value: ${ethers.formatUnits(usdcVal, 6)} USDC`);
    console.log(`   NFT Eligible: ${await vault.isNFTEligible(addr)}`);
  }

  console.log('\n✅ Tests complete');
}

main().catch(e => { console.error(e); process.exit(1); });
