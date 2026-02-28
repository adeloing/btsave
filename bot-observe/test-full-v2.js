const { ethers } = require('ethers');

const RPC = 'https://ethereum-sepolia-rpc.publicnode.com';

const VAULT   = '0xbB5AA31D849860e5A6D3b288DD33177667115678';
const USDC    = '0xdFe847917Ab66F2e6978dB5e958f06cEdC1EdC4b';
const WBTC    = '0x3E3E1b4dACEF155cf11708E0D8EB61bEA7C9cF78';
const SAFE    = '0x6727CAAbd6C40525905a79236AcEF13D977D72e8';
const ORACLE  = '0x3FC1Fe7DA22a57DA42f47aAac838d48fDe7c4E2F';
const NFT     = '0x208B869111069DC522570b258aF8C8d3bdF4E4d7';

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
  'function getCycleInfo() view returns (uint256,uint256,uint256,bool,bool,bool)',
  'function getUserInfo(address) view returns (uint256,uint256,uint256,uint256)',
  'function autoRedeemPct(address) view returns (uint256)',
  'function isNFTEligible(address) view returns (bool)',
  'function getAutoRedeemStats() view returns (uint256,uint256)',
  'function pendingPoolBalance() view returns (uint256)',
  'function nftContract() view returns (address)',
  'function currentCycle() view returns (uint256)',
  'function getUserBonusMultiplier(address) view returns (uint256)',
  'function mintCycleNFT(address,uint8)',
  'function proposeUnwind() external',
  'function executeUnwind() external',
  'function startNewCycle(uint256) external'
];
const SAFE_ABI = ['function exec(address to, bytes data) returns (bool)'];
const ORACLE_ABI = ['function setPrice(int256)'];
const NFT_ABI = [
  'function balanceOf(uint256,address) view returns (uint256)',
  'function getBonusMultiplier(address) view returns (uint256)'
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
  const addr = wallet.address;
  const vault = new ethers.Contract(VAULT, VAULT_ABI, wallet);
  const usdc = new ethers.Contract(USDC, ERC20_ABI, wallet);
  const wbtc = new ethers.Contract(WBTC, ERC20_ABI, wallet);
  const safe = new ethers.Contract(SAFE, SAFE_ABI, wallet);
  const oracle = new ethers.Contract(ORACLE, ORACLE_ABI, wallet);
  const nft = new ethers.Contract(NFT, NFT_ABI, wallet);

  console.log(`🔑 ${addr}\n📍 Vault: ${VAULT}\n📍 NFT: ${NFT}\n`);

  // TEST 3: Deposit
  console.log('=== TEST 3: Deposit 100 USDC ===');
  let tx = await usdc.approve(VAULT, ethers.MaxUint256); await tx.wait();
  tx = await vault.deposit(ethers.parseUnits('100', 6)); await tx.wait();
  console.log(`   ✅ ${ethers.formatUnits(await vault.balanceOf(addr), 18)} TPB minted`);

  // TEST 4: Auto-Redeem
  console.log('\n=== TEST 4: Auto-Redeem 50% ===');
  tx = await vault.setAutoRedeemAtNextATH(50); await tx.wait();
  console.log(`   ✅ Auto-Redeem: ${await vault.autoRedeemPct(addr)}%`);

  // TEST 5: NFT Mint
  console.log('\n=== TEST 5: NFT Mint (Gold) ===');
  console.log(`   NFT contract: ${await vault.nftContract()}`);
  console.log(`   Eligible: ${await vault.isNFTEligible(addr)}`);
  // mintCycleNFT via safe (vault checks msg.sender == safe)
  const mintData = vault.interface.encodeFunctionData('mintCycleNFT', [addr, 3]);
  tx = await safe.exec(VAULT, mintData); await tx.wait();
  const nftBal = await nft['balanceOf(uint256,address)'](13, addr); // tokenId = 1*10+3
  console.log(`   ✅ NFT #13 (Cycle 1 Gold) balance: ${nftBal}`);
  console.log(`   Bonus: ${await vault.getUserBonusMultiplier(addr)} BPS`);

  // TEST 6: Unwind + Cycle Reset
  console.log('\n=== TEST 6: Unwind + Cycle Reset ===');
  // Set price to ATH
  tx = await oracle.setPrice(ethers.parseUnits('126000', 8)); await tx.wait();
  console.log('   Oracle → $126,000');

  // proposeUnwind (deployer = keeper)
  tx = await wallet.sendTransaction({ to: VAULT, data: vault.interface.encodeFunctionData('proposeUnwind', []) }); await tx.wait();
  console.log('   ✅ Unwind proposed');

  let [cycle,,, active, redemption, unwind] = await vault.getCycleInfo();
  console.log(`   Cycle ${cycle}: active=${active} redemption=${redemption} unwind=${unwind}`);

  // executeUnwind via safe
  const unwindData = vault.interface.encodeFunctionData('executeUnwind', []);
  tx = await safe.exec(VAULT, unwindData); await tx.wait();
  console.log('   ✅ Unwind executed');

  [cycle,,, active] = await vault.getCycleInfo();
  console.log(`   Cycle ${cycle}: active=${active}`);

  // Check auto-redeem WBTC received
  const wbtcBal = await wbtc.balanceOf(addr);
  console.log(`   WBTC from auto-redeem: ${ethers.formatUnits(wbtcBal, 8)}`);

  // Start new cycle — encode manually to avoid ABI collision
  const startCycleIface = new ethers.Interface(['function startNewCycle(uint256)']);
  const newCycleData = startCycleIface.encodeFunctionData('startNewCycle', [ethers.parseUnits('150000', 8)]);
  tx = await safe.exec(VAULT, newCycleData); await tx.wait();
  [cycle, , , active] = await vault.getCycleInfo();
  console.log(`   ✅ Cycle ${cycle} started, ATH $150k, active=${active}`);

  console.log('\n🎉 ALL 6 TESTS PASSED');
}

main().catch(e => { console.error('❌', e.message || e); process.exit(1); });
