globalThis.fetch = async () => new Response(JSON.stringify({latest: JSON.parse(process.env.E2E_MANIFEST)}));
