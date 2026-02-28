const { ethers } = require('ethers');

const RPC = 'https://ethereum-sepolia-rpc.publicnode.com';

// New full deployment addresses
const VAULT   = '0xbb6603aa6be5fa5cc16a1ba4bc28fd16757def2f';
const USDC    = '0x454ecc7b8f736331050cc606ca985794ce5c5071';
const WBTC    = '0x4a8564528088fb3837a2778a06d7c0745f3a8b94';
const SAFE    = '0xf34cfec9f2e25d9b0e700e974772cbab54444c2d';
const ORACLE  = '0x7594751e6e2f462c54ad32c864e01d8224793034';
const LSM     = '0x4b6e56708daa8ef3b09ed6da4deb0fcd480552d0';
const NFT     = '0x79dd710734b118bf75f57153016cf1e5a628d35c';
const TARGET  = '0xa2cc3cc21d7ff51058d4142c06ce5e535fd44123';

const ERC20_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function mint(address,uint256)'
];

const VAULT_ABI = [
  'function deposit(uint256)',
  'function setAutoRedeemAtNextATH(uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function getNav() view returns (uint256)',
  'function getCycleInfo() view returns (uint256,uint256,uint256,bool,bool,bool)',
  'function getUserInfo(address) view returns (uint256,uint256,uint256,uint256)',
  'function autoRedeemPct(address) view returns (uint256)',
  'function isNFTEligible(address) view returns (bool)',
  'function getAutoRedeemStats() view returns (uint256,uint256)',
  'function pendingPoolBalance() view returns (uint256)',
  'function nftContract() view returns (address)',
  'function proposeUnwind()',
  'function executeUnwind()',
  'function autoExecuteUnwind()',
  'function startNewCycle(uint256)',
  'function mintCycleNFT(address,uint8)',
  'function currentCycle() view returns (uint256)',
  'function getUserBonusMultiplier(address) view returns (uint256)'
];

const SAFE_ABI = ['function exec(address,bytes) returns (bool,bytes)'];
const ORACLE_ABI = ['function setPrice(int256)'];
const NFT_ABI = [
  'function balanceOf(uint256,address) view returns (uint256)',
  'function getBonusMultiplier(address) view returns (uint256)',
  'function getBonusBreakdown(address) view returns (uint256,uint8,bool,uint256,uint256,uint256,uint256)'
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
  const addr = wallet.address;

  const usdc = new ethers.Contract(USDC, ERC20_ABI, wallet);
  const vault = new ethers.Contract(VAULT, VAULT_ABI, wallet);
  const safe = new ethers.Contract(SAFE, SAFE_ABI, wallet);
  const oracle = new ethers.Contract(ORACLE, ORACLE_ABI, wallet);
  const nft = new ethers.Contract(NFT, NFT_ABI, wallet);

  console.log(`🔑 Deployer: ${addr}`);
  console.log(`📍 Vault: ${VAULT}`);
  console.log(`📍 NFT: ${NFT}`);

  // ===== TEST 3: Deposit =====
  console.log('\n=== TEST 3: Deposit 100 USDC ===');
  let tx = await usdc.approve(VAULT, ethers.parseUnits('1000000', 6));
  await tx.wait();
  tx = await vault.deposit(ethers.parseUnits('100', 6));
  await tx.wait();
  const tpbBal = await vault.balanceOf(addr);
  console.log(`   ✅ Deposited 100 USDC → ${ethers.formatUnits(tpbBal, 18)} TPB`);

  // ===== TEST 4: Auto-Redeem =====
  console.log('\n=== TEST 4: Set Auto-Redeem 50% ===');
  tx = await vault.setAutoRedeemAtNextATH(50);
  await tx.wait();
  console.log(`   ✅ Auto-Redeem set to ${await vault.autoRedeemPct(addr)}%`);

  // ===== TEST 5: NFT Mint =====
  console.log('\n=== TEST 5: NFT Mint ===');
  const nftAddr = await vault.nftContract();
  console.log(`   NFT contract in vault: ${nftAddr}`);
  console.log(`   NFT Eligible: ${await vault.isNFTEligible(addr)}`);

  // To mint, we need to end the cycle first OR mint directly
  // mintCycleNFT requires !cycleActive or cycle==1
  // Current cycle is 1 and active — the function allows cycle==1
  // Call via safe since vault.mintCycleNFT needs keeper or safe
  const mintCalldata = vault.interface.encodeFunctionData('mintCycleNFT', [addr, 3]); // Gold tier
  tx = await safe.exec(VAULT, mintCalldata);
  await tx.wait();

  // Check NFT - tokenId = cycle * 10 + tier = 1 * 10 + 3 = 13
  const nftBal = await nft['balanceOf(uint256,address)'](13, addr);
  console.log(`   ✅ NFT #13 (Cycle 1, Gold) balance: ${nftBal}`);

  const bonus = await vault.getUserBonusMultiplier(addr);
  console.log(`   Bonus multiplier: ${bonus} BPS (${Number(bonus)/10000}×)`);

  // ===== TEST 6: Cycle Reset =====
  console.log('\n=== TEST 6: Unwind + Cycle Reset ===');

  // Set oracle to ATH ($126,000) to allow proposeUnwind
  tx = await oracle.setPrice(ethers.parseUnits('126000', 8));
  await tx.wait();
  console.log('   Oracle set to $126,000');

  // proposeUnwind — requires onlyKeeper (deployer is keeper via LSM)
  tx = await vault.proposeUnwind();
  await tx.wait();
  console.log('   ✅ Unwind proposed');

  let [cycle, ath, , active, redemption, unwind] = await vault.getCycleInfo();
  console.log(`   Cycle ${cycle}: active=${active}, redemptionOpen=${redemption}, unwindPending=${unwind}`);

  // executeUnwind — requires onlySafe, call via MockSafe
  const unwindCalldata = vault.interface.encodeFunctionData('executeUnwind', []);
  tx = await safe.exec(VAULT, unwindCalldata);
  await tx.wait();
  console.log('   ✅ Unwind executed');

  [cycle, ath, , active, redemption, unwind] = await vault.getCycleInfo();
  console.log(`   Cycle ${cycle}: active=${active}, redemptionOpen=${redemption}`);

  // Check WBTC received from auto-redeem
  const wbtcBal = await (new ethers.Contract(WBTC, ERC20_ABI, wallet)).balanceOf(addr);
  console.log(`   WBTC balance after auto-redeem: ${ethers.formatUnits(wbtcBal, 8)}`);

  // Start new cycle
  const newATH = ethers.parseUnits('150000', 8);
  const newCycleCalldata = vault.interface.encodeFunctionData('startNewCycle', [newATH]);
  tx = await safe.exec(VAULT, newCycleCalldata);
  await tx.wait();

  [cycle, ath, , active] = await vault.getCycleInfo();
  console.log(`   ✅ New cycle started: Cycle ${cycle}, ATH $${ethers.formatUnits(ath, 8)}, active=${active}`);

  // Final status
  console.log('\n=== FINAL STATUS ===');
  const [bal, redeem, share, usdcVal] = await vault.getUserInfo(addr);
  console.log(`   TPB balance: ${ethers.formatUnits(bal, 18)}`);
  console.log(`   Auto-Redeem: ${redeem}%`);
  console.log(`   NFT Eligible: ${await vault.isNFTEligible(addr)}`);

  console.log('\n🎉 ALL TESTS COMPLETE');
}

main().catch(e => { console.error('❌ ERROR:', e.message || e); process.exit(1); });
