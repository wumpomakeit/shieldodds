/**
 * Vercel Serverless RPC Proxy
 *
 * Forwards JSON-RPC requests to Alchemy so the API key never
 * reaches the browser.
 *
 * Environment variable required (set in Vercel dashboard):
 *   ALCHEMY_RPC_URL — full Alchemy endpoint including key
 *                     e.g. https://eth-sepolia.g.alchemy.com/v2/<key>
 */

// Allowed JSON-RPC methods — whitelist to prevent abuse.
const ALLOWED_METHODS = new Set([
  // Read-only state
  'eth_call',
  'eth_getBalance',
  'eth_getTransactionReceipt',
  'eth_getTransactionByHash',
  'eth_blockNumber',
  'eth_getBlockByNumber',
  'eth_getBlockByHash',
  'eth_getLogs',
  'eth_getCode',
  'eth_getStorageAt',
  'eth_getTransactionCount',
  'eth_estimateGas',
  'eth_gasPrice',
  'eth_maxPriorityFeePerGas',
  'eth_feeHistory',
  'eth_chainId',
  'net_version',
  // Sending signed transactions
  'eth_sendRawTransaction',
]);

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}

module.exports = async function handler(req, res) {
  // --- CORS preflight ---
  if (req.method === 'OPTIONS') {
    res.writeHead(204, corsHeaders());
    res.end();
    return;
  }

  // --- Only POST ---
  if (req.method !== 'POST') {
    res.writeHead(405, { ...corsHeaders(), 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32600, message: 'Only POST allowed' }, id: null }));
    return;
  }

  // --- Check env ---
  const alchemyUrl = process.env.ALCHEMY_RPC_URL;
  if (!alchemyUrl) {
    res.writeHead(500, { ...corsHeaders(), 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32603, message: 'RPC endpoint not configured' }, id: null }));
    return;
  }

  // --- Validate body ---
  const body = req.body;
  if (!body || typeof body !== 'object') {
    res.writeHead(400, { ...corsHeaders(), 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32600, message: 'Invalid request body' }, id: null }));
    return;
  }

  // Support batched requests (array) and single requests
  const requests = Array.isArray(body) ? body : [body];

  for (const rpcReq of requests) {
    if (!rpcReq.method || !ALLOWED_METHODS.has(rpcReq.method)) {
      res.writeHead(403, { ...corsHeaders(), 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        jsonrpc: '2.0',
        error: { code: -32601, message: `Method not allowed: ${rpcReq.method || '(empty)'}` },
        id: rpcReq.id ?? null,
      }));
      return;
    }
  }

  // --- Forward to Alchemy ---
  try {
    const upstream = await fetch(alchemyUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });

    const data = await upstream.text();

    res.writeHead(upstream.status, {
      ...corsHeaders(),
      'Content-Type': 'application/json',
    });
    res.end(data);
  } catch (err) {
    console.error('RPC proxy error:', err);
    res.writeHead(502, { ...corsHeaders(), 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      jsonrpc: '2.0',
      error: { code: -32603, message: 'Upstream RPC request failed' },
      id: null,
    }));
  }
};
