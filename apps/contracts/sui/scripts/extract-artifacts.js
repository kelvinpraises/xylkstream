#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const BUILD_DIR = path.join(__dirname, '../build/xylkstream/bytecode_modules');
const PUBLIC_DIR = path.join(__dirname, '../../../client/public/contracts');

// Ensure output directory exists
if (!fs.existsSync(PUBLIC_DIR)) {
  fs.mkdirSync(PUBLIC_DIR, { recursive: true });
}

console.log('🔨 Building Sui Move package...\n');

try {
  // Build the package with base64 bytecode output
  execSync('sui move build --dump-bytecode-as-base64', {
    cwd: path.join(__dirname, '..'),
    stdio: 'inherit',
  });
} catch (error) {
  console.error('❌ Build failed');
  process.exit(1);
}

console.log('\n📦 Extracting bytecode modules...\n');

if (!fs.existsSync(BUILD_DIR)) {
  console.error(`❌ Build output not found at: ${BUILD_DIR}`);
  process.exit(1);
}

// Get all .mv files (compiled modules)
const moduleFiles = fs.readdirSync(BUILD_DIR).filter(f => f.endsWith('.mv'));

if (moduleFiles.length === 0) {
  console.error('❌ No compiled modules found');
  process.exit(1);
}

// Read all modules as base64
const modules = moduleFiles.map(file => {
  const modulePath = path.join(BUILD_DIR, file);
  const bytecode = fs.readFileSync(modulePath);
  return {
    name: file.replace('.mv', ''),
    bytecode: bytecode.toString('base64'),
    size: bytecode.length,
  };
});

// Create the artifact file
const artifact = {
  packageName: 'xylkstream',
  modules: modules.map(m => ({
    name: m.name,
    bytecode: m.bytecode,
  })),
  dependencies: [
    '0x1', // MoveStdlib
    '0x2', // Sui framework
  ],
};

const outputPath = path.join(PUBLIC_DIR, 'sui-package.json');
fs.writeFileSync(outputPath, JSON.stringify(artifact, null, 2));

console.log(`✅ Sui package artifact created`);
console.log(`   Modules: ${modules.length}`);
modules.forEach(m => {
  console.log(`   - ${m.name} (${m.size.toLocaleString()} bytes)`);
});
console.log(`\n✨ Artifact saved to: ${outputPath}`);
