#!/usr/bin/env node
/**
 * BTSAVE Test Notifications Script
 * Envoie 3 exemples de notifications pour tester le système
 */

const { sendTestNotification } = require('./notifier');

async function sendAllTests() {
  console.log('🧪 Envoi des notifications de test BTSAVE...\n');

  try {
    console.log('1. 📉 Test palier baisse normal (Step 2 - Zone accumulation)');
    console.log('   Prix: $113,400 - Palier 2 franchi en baisse');
    await sendTestNotification('step_down');
    console.log('   ✅ Envoyé!\n');
    
    // Wait 2 seconds between tests
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    console.log('2. ⚠️  Test palier baisse profond (Step 3 - Accumulation + HF check)');
    console.log('   Prix: $107,100 - Palier 3 franchi, vérifier Health Factor');
    await sendTestNotification('critical_zone');
    console.log('   ✅ Envoyé!\n');
    
    // Wait 2 seconds between tests
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    console.log('3. 🚀 Test nouvel ATH');
    console.log('   Prix: $128,500 - Nouveau record historique, reset du cycle');
    await sendTestNotification('new_ath');
    console.log('   ✅ Envoyé!\n');
    
    console.log('🎉 Toutes les notifications de test ont été envoyées avec succès!');
    console.log('📱 Vérifiez Telegram chat ID: REDACTED_CHAT_ID');
    
  } catch (error) {
    console.error('❌ Erreur lors de l\'envoi des tests:', error.message);
    process.exit(1);
  }
}

async function sendSingleTest(scenario) {
  const scenarios = {
    'step': 'step_down',
    'critical': 'critical_zone', 
    'ath': 'new_ath'
  };
  
  const testScenario = scenarios[scenario];
  if (!testScenario) {
    console.error('❌ Scénario invalide. Utilisez: step, critical, ou ath');
    process.exit(1);
  }
  
  console.log(`🧪 Envoi du test: ${scenario}`);
  try {
    await sendTestNotification(testScenario);
    console.log('✅ Test envoyé avec succès!');
  } catch (error) {
    console.error('❌ Erreur:', error.message);
    process.exit(1);
  }
}

// CLI usage
const args = process.argv.slice(2);

if (args.length === 0) {
  // Send all tests
  sendAllTests();
} else if (args.length === 1) {
  // Send specific test
  sendSingleTest(args[0]);
} else {
  console.log('Usage:');
  console.log('  node send-test-notifications.js           # Envoie tous les tests');
  console.log('  node send-test-notifications.js step      # Test palier baisse');
  console.log('  node send-test-notifications.js critical  # Test zone critique');
  console.log('  node send-test-notifications.js ath       # Test nouvel ATH');
  process.exit(1);
}