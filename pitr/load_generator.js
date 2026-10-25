const { Client } = require('pg');

const client = new Client({
    host: process.env.PG_HOST || 'localhost',
    port: parseInt(process.env.PG_PORT || '5432', 10),
    user: process.env.PG_USER || 'postgres',
    password: process.env.PG_PASSWORD || '',
    database: process.env.PG_DATABASE || 'microps',
    ssl: process.env.PG_SSL === 'true' ? { rejectUnauthorized: false } : false
});

async function runGenerator() {
    await client.connect();
    console.log(`[PITR Generator] Connected to database: ${client.database} at ${client.host}:${client.port}`);

    // Ensure heartbeat table exists
    await client.query(`
        CREATE TABLE IF NOT EXISTS pitr_heartbeat (
            seq BIGSERIAL PRIMARY KEY,
            recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
            tag VARCHAR(64) NOT NULL
        );
    `);

    let iteration = 0;

    while (true) {
        try {
            iteration++;
            const email = `user_${Date.now()}_${iteration}@pitr-lab.test`;
            const name = `Test User ${iteration}`;

            // 1. Continuous regular transaction
            await client.query('BEGIN');
            
            const userRes = await client.query(
                `INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id`,
                [name, email]
            );

            // 2. Heartbeat marker row for precise RPO measurement
            const hbRes = await client.query(
                `INSERT INTO pitr_heartbeat (tag) VALUES ($1) RETURNING seq, recorded_at`,
                [`live_traffic`]
            );
            
            await client.query('COMMIT');

            const { seq, recorded_at } = hbRes.rows[0];
            const tsIso = new Date(recorded_at).toISOString();

            if (iteration % 10 === 0) {
                console.log(`[${tsIso}] Committed seq: ${seq} | User: ${email}`);
            } else {
                process.stdout.write('.');
            }

            // Variable delay between 100ms - 300ms
            const delay = Math.floor(Math.random() * 200) + 100;
            await new Promise(resolve => setTimeout(resolve, delay));

        } catch (err) {
            await client.query('ROLLBACK').catch(() => {});
            console.error('\n[Generator Error]:', err.message);
            await new Promise(resolve => setTimeout(resolve, 1000));
        }
    }
}

process.on('SIGINT', async () => {
    console.log('\n[PITR Generator] Gracefully stopping...');
    await client.end().catch(() => {});
    process.exit(0);
});

runGenerator();
