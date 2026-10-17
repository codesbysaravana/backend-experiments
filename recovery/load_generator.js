const { Client } = require('pg');
const { faker } = require('@faker-js/faker');

const client = new Client({
    host: process.env.PG_HOST || 'localhost',
    port: parseInt(process.env.PG_PORT || '5432'),
    user: process.env.PG_USER || 'postgres',
    password: process.env.PG_PASSWORD || '',
    database: process.env.PG_DATABASE || 'postgres',
    ssl: process.env.PG_SSL === 'true' ? { rejectUnauthorized: false } : false
});

async function runGenerator() {
    await client.connect();
    console.log("Connected to AWS RDS...");

    while (true) {
        try {
            const userRes = await client.query(
                `INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id`,
                [faker.person.fullName(), faker.internet.email()]
            );
            const userId = userRes.rows[0].id;

            const orgRes = await client.query(
                `INSERT INTO organizations (name, slug, type) VALUES ($1, $2, 'STARTUP') RETURNING id`,
                [faker.company.name(), faker.helpers.slugify(faker.company.name()).toLowerCase()]
            );
            const orgId = orgRes.rows[0].id;

            await client.query(
                `INSERT INTO projects (user_id, org_id, name, repo_url) VALUES ($1, $2, $3, $4)`,
                [userId, orgId, faker.commerce.productName(), faker.internet.url()]
            );

            process.stdout.write('.');

            //delay bef next batch
            const delay = Math.floor(Math.random() * 400) + 100;
            await new Promise(resolve => setTimeout(resolve, delay)); //timing until promise breaks


        } catch (err) {
            if (err.code !== '23505') {
                console.error("\nError:", err.message);
            }
        }
    }
}

runGenerator();
