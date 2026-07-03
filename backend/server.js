'use strict';

/**
 * BookNook API — everything in one file.
 *
 * Adds login & roles on top of the bookstore:
 *   - users table (admin / normal) with bcrypt-hashed passwords
 *   - POST /api/login issues a JWT; all other /api routes require it
 *   - admin-only routes to add/remove books and view every order
 *   - cart & orders are scoped to the logged-in user
 *
 * On startup it creates the database + 5 tables if missing, seeds sample
 * books, and seeds 3 demo users (admin/alice/bob). DB creds come from .env.
 */

require('dotenv').config();
const express = require('express');
const cors = require('cors');
const mysql = require('mysql2/promise');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');

const PORT = Number(process.env.PORT) || 3000;
const JWT_SECRET = process.env.JWT_SECRET || 'dev-insecure-secret-change-me';
const TOKEN_TTL = '8h';

const dbConfig = {
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT) || 3306,
  user: process.env.DB_USER || 'root',
  password: process.env.DB_PASSWORD || '',
  database: process.env.DB_NAME || 'booknook',
  charset: 'utf8mb4',
};

let pool;

// ── seed data ────────────────────────────────────────────────
const SAMPLE_BOOKS = [
  ['The Pragmatic Programmer', 'Andrew Hunt & David Thomas', 'Technology', 42.99, 'Your journey to mastery — timeless lessons for writing better software.'],
  ['Clean Code', 'Robert C. Martin', 'Technology', 38.5, 'A handbook of agile software craftsmanship.'],
  ['Designing Data-Intensive Applications', 'Martin Kleppmann', 'Technology', 49.99, 'The big ideas behind reliable, scalable systems.'],
  ['Sapiens', 'Yuval Noah Harari', 'History', 24.99, 'A brief history of humankind.'],
  ['Atomic Habits', 'James Clear', 'Self-Help', 19.99, 'An easy and proven way to build good habits.'],
  ['The Midnight Library', 'Matt Haig', 'Fiction', 16.99, 'Between life and death there is a library.'],
  ['Project Hail Mary', 'Andy Weir', 'Science Fiction', 22.5, 'A lone astronaut must save the earth.'],
  ['Dune', 'Frank Herbert', 'Science Fiction', 18.99, 'The epic saga of the desert planet Arrakis.'],
  ['Educated', 'Tara Westover', 'Memoir', 17.99, 'A memoir about leaving a survivalist family for a PhD.'],
  ['Thinking, Fast and Slow', 'Daniel Kahneman', 'Psychology', 21.0, 'The two systems that drive the way we think.'],
  ['The Silent Patient', 'Alex Michaelides', 'Thriller', 15.99, 'A psychotherapist uncovers a silent murderer.'],
  ['Where the Crawdads Sing', 'Delia Owens', 'Fiction', 18.0, 'A coming-of-age murder mystery in the marshes.'],
];

// username, password, role
const SAMPLE_USERS = [
  ['admin', 'admin123', 'admin'],
  ['alice', 'alice123', 'user'],
  ['bob', 'bob123', 'user'],
];

async function initDb() {
  const conn = await mysql.createConnection({ host: dbConfig.host, port: dbConfig.port, user: dbConfig.user, password: dbConfig.password });
  await conn.query(`CREATE DATABASE IF NOT EXISTS \`${dbConfig.database}\` CHARACTER SET utf8mb4`);
  await conn.end();

  pool = mysql.createPool({ ...dbConfig, waitForConnections: true, connectionLimit: 10 });

  await pool.query(`CREATE TABLE IF NOT EXISTS users (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    password_hash VARCHAR(100) NOT NULL,
    role VARCHAR(10) NOT NULL DEFAULT 'user',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`);

  await pool.query(`CREATE TABLE IF NOT EXISTS books (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    title VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL,
    category VARCHAR(100) NOT NULL, price DECIMAL(8,2) NOT NULL,
    description TEXT) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`);

  await pool.query(`CREATE TABLE IF NOT EXISTS cart_items (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id INT UNSIGNED NOT NULL, book_id INT UNSIGNED NOT NULL,
    quantity INT UNSIGNED NOT NULL DEFAULT 1,
    UNIQUE KEY uq (user_id, book_id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`);

  await pool.query(`CREATE TABLE IF NOT EXISTS orders (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    user_id INT UNSIGNED NOT NULL, customer_name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL, address VARCHAR(512) NOT NULL,
    total DECIMAL(10,2) NOT NULL, status VARCHAR(20) NOT NULL DEFAULT 'placed',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`);

  await pool.query(`CREATE TABLE IF NOT EXISTS order_items (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    order_id INT UNSIGNED NOT NULL, title VARCHAR(255) NOT NULL,
    price DECIMAL(8,2) NOT NULL, quantity INT UNSIGNED NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4`);

  const [[{ nb }]] = await pool.query('SELECT COUNT(*) AS nb FROM books');
  if (nb === 0) {
    await pool.query('INSERT INTO books (title, author, category, price, description) VALUES ?', [SAMPLE_BOOKS]);
    console.log(`Seeded ${SAMPLE_BOOKS.length} books.`);
  }

  const [[{ nu }]] = await pool.query('SELECT COUNT(*) AS nu FROM users');
  if (nu === 0) {
    const rows = SAMPLE_USERS.map(([u, p, r]) => [u, bcrypt.hashSync(p, 10), r]);
    await pool.query('INSERT INTO users (username, password_hash, role) VALUES ?', [rows]);
    console.log(`Seeded ${rows.length} users (admin / alice / bob).`);
  }
}

// ── app ──────────────────────────────────────────────────────
const app = express();
app.use(cors({ origin: process.env.CORS_ORIGIN || '*', allowedHeaders: ['Content-Type', 'Authorization'] }));
app.use(express.json());

// auth middleware — verifies the Bearer token and sets req.user
function auth(req, res, next) {
  const h = req.get('Authorization') || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : '';
  if (!token) return res.status(401).json({ error: 'Not authenticated' });
  try {
    req.user = jwt.verify(token, JWT_SECRET); // { id, username, role }
    next();
  } catch {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}

function adminOnly(req, res, next) {
  if (req.user.role !== 'admin') return res.status(403).json({ error: 'Admin only' });
  next();
}

app.get('/health', async (req, res) => {
  try { await pool.query('SELECT 1'); res.json({ status: 'healthy' }); }
  catch { res.status(503).json({ status: 'unhealthy' }); }
});

// ── auth routes ──────────────────────────────────────────────
app.post('/api/login', async (req, res) => {
  const { username, password } = req.body || {};
  if (!username || !password) return res.status(400).json({ error: 'Username and password required' });
  const [rows] = await pool.query('SELECT * FROM users WHERE username = ?', [username]);
  const user = rows[0];
  if (!user || !bcrypt.compareSync(password, user.password_hash)) {
    return res.status(401).json({ error: 'Invalid username or password' });
  }
  const token = jwt.sign({ id: user.id, username: user.username, role: user.role }, JWT_SECRET, { expiresIn: TOKEN_TTL });
  res.json({ token, user: { id: user.id, username: user.username, role: user.role } });
});

app.get('/api/me', auth, (req, res) => {
  res.json({ id: req.user.id, username: req.user.username, role: req.user.role });
});

// everything below requires a valid token
app.use('/api', auth);

// ── books (read for all; write for admin) ────────────────────
app.get('/api/books', async (req, res) => {
  const { search, category } = req.query;
  const where = [], params = [];
  if (search) { where.push('(title LIKE ? OR author LIKE ?)'); params.push(`%${search}%`, `%${search}%`); }
  if (category) { where.push('category = ?'); params.push(category); }
  const clause = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const [rows] = await pool.query(`SELECT * FROM books ${clause} ORDER BY title`, params);
  res.json(rows);
});

app.get('/api/categories', async (req, res) => {
  const [rows] = await pool.query('SELECT category, COUNT(*) AS count FROM books GROUP BY category ORDER BY category');
  res.json(rows);
});

app.post('/api/books', adminOnly, async (req, res) => {
  const { title, author, category, price, description } = req.body || {};
  if (!title || !author || !category || price == null) return res.status(400).json({ error: 'Missing required fields' });
  const [r] = await pool.query(
    'INSERT INTO books (title, author, category, price, description) VALUES (?, ?, ?, ?, ?)',
    [title, author, category, Number(price), description || '']);
  res.status(201).json({ ok: true, id: r.insertId });
});

app.delete('/api/books/:id', adminOnly, async (req, res) => {
  await pool.query('DELETE FROM cart_items WHERE book_id = ?', [req.params.id]);
  await pool.query('DELETE FROM books WHERE id = ?', [req.params.id]);
  res.json({ ok: true });
});

// ── cart (scoped to the logged-in user) ──────────────────────
app.get('/api/cart', async (req, res) => {
  const [items] = await pool.query(
    `SELECT c.id, c.quantity, b.id AS book_id, b.title, b.author, b.price,
            (b.price * c.quantity) AS line_total
       FROM cart_items c JOIN books b ON b.id = c.book_id
      WHERE c.user_id = ? ORDER BY c.id`, [req.user.id]);
  const subtotal = items.reduce((s, i) => s + Number(i.line_total), 0);
  const count = items.reduce((s, i) => s + i.quantity, 0);
  res.json({ items, subtotal: Number(subtotal.toFixed(2)), count });
});

app.post('/api/cart', async (req, res) => {
  const qty = Math.max(1, Number(req.body.quantity) || 1);
  await pool.query(
    `INSERT INTO cart_items (user_id, book_id, quantity) VALUES (?, ?, ?)
     ON DUPLICATE KEY UPDATE quantity = quantity + VALUES(quantity)`,
    [req.user.id, Number(req.body.book_id), qty]);
  res.status(201).json({ ok: true });
});

app.put('/api/cart/:id', async (req, res) => {
  const qty = Number(req.body.quantity);
  if (qty <= 0) await pool.query('DELETE FROM cart_items WHERE id = ? AND user_id = ?', [req.params.id, req.user.id]);
  else await pool.query('UPDATE cart_items SET quantity = ? WHERE id = ? AND user_id = ?', [qty, req.params.id, req.user.id]);
  res.json({ ok: true });
});

app.delete('/api/cart/:id', async (req, res) => {
  await pool.query('DELETE FROM cart_items WHERE id = ? AND user_id = ?', [req.params.id, req.user.id]);
  res.json({ ok: true });
});

// ── orders ───────────────────────────────────────────────────
app.post('/api/orders', async (req, res) => {
  const { customer_name, email, address } = req.body || {};
  if (!customer_name || !email || !address) return res.status(400).json({ error: 'Missing required fields' });
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const [items] = await conn.query(
      `SELECT b.title, b.price, c.quantity FROM cart_items c
        JOIN books b ON b.id = c.book_id WHERE c.user_id = ?`, [req.user.id]);
    if (items.length === 0) { await conn.rollback(); return res.status(400).json({ error: 'Cart is empty' }); }
    const total = items.reduce((s, i) => s + Number(i.price) * i.quantity, 0);
    const [r] = await conn.query(
      'INSERT INTO orders (user_id, customer_name, email, address, total) VALUES (?, ?, ?, ?, ?)',
      [req.user.id, customer_name, email, address, total.toFixed(2)]);
    await conn.query('INSERT INTO order_items (order_id, title, price, quantity) VALUES ?',
      [items.map((i) => [r.insertId, i.title, i.price, i.quantity])]);
    await conn.query('DELETE FROM cart_items WHERE user_id = ?', [req.user.id]);
    await conn.commit();
    res.status(201).json({ ok: true, order_id: r.insertId, total: Number(total.toFixed(2)) });
  } catch (e) { await conn.rollback(); res.status(500).json({ error: 'Checkout failed' }); }
  finally { conn.release(); }
});

// a normal user sees their own orders
app.get('/api/orders', async (req, res) => {
  const [orders] = await pool.query('SELECT * FROM orders WHERE user_id = ? ORDER BY created_at DESC', [req.user.id]);
  for (const o of orders) {
    const [items] = await pool.query('SELECT title, price, quantity FROM order_items WHERE order_id = ?', [o.id]);
    o.items = items;
  }
  res.json(orders);
});

// admin sees ALL orders (with the username that placed each)
app.get('/api/admin/orders', adminOnly, async (req, res) => {
  const [orders] = await pool.query(
    `SELECT o.*, u.username FROM orders o JOIN users u ON u.id = o.user_id
      ORDER BY o.created_at DESC`);
  for (const o of orders) {
    const [items] = await pool.query('SELECT title, price, quantity FROM order_items WHERE order_id = ?', [o.id]);
    o.items = items;
  }
  res.json(orders);
});

// ── start ────────────────────────────────────────────────────
initDb()
  .then(() => app.listen(PORT, () => console.log(`BookNook API on http://localhost:${PORT}`)))
  .catch((err) => { console.error('Startup failed:', err.message); process.exit(1); });
