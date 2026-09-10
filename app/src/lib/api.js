import bcrypt from 'bcryptjs';
import { error } from '@sveltejs/kit';
import { pool } from './server/db.js';

// --- auth token helpers -----------------------------------------------
// The app already base64-encodes whatever `user.token` we hand back into a
// cookie (see src/hooks.server.js) and returns it to us on every subsequent
// call. It doesn't need to be a cryptographically real JWT for this to
// work — it just needs to be something we can turn back into a user id.
// Don't ship this token scheme anywhere that matters.
function encodeToken(userId) {
  return Buffer.from(`uid:${userId}`).toString('base64');
}

function decodeToken(token) {
  if (!token) return null;
  try {
    const match = Buffer.from(token, 'base64').toString('utf8').match(/^uid:(\d+)$/);
    return match ? Number(match[1]) : null;
  } catch {
    return null;
  }
}

function toUserJson(row) {
  return {
    email: row.email,
    username: row.username,
    bio: row.bio ?? '',
    image: row.image,
    token: encodeToken(row.id)
  };
}

function slugify(title) {
  const base = title.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '');
  return `${base}-${Math.random().toString(36).slice(2, 8)}`;
}

function mapArticleRow(row) {
  return {
    slug: row.slug,
    title: row.title,
    description: row.description,
    body: row.body,
    tagList: row.tag_list ?? [],
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    favorited: row.favorited,
    favoritesCount: Number(row.favorites_count),
    author: {
      username: row.author_username,
      bio: row.author_bio ?? '',
      image: row.author_image,
      following: row.following
    }
  };
}

// --- articles -----------------------------------------------------------

async function listArticles({ tag, author, favorited, feedFor, limit, offset }, currentUserId) {
  const params = [currentUserId ?? null];
  const conditions = [];

  if (feedFor && !currentUserId) error(401);

  if (tag) {
    params.push(tag);
    conditions.push(`a.id IN (SELECT article_id FROM article_tags WHERE tag_name = $${params.length})`);
  }
  if (author) {
    params.push(author);
    conditions.push(`u.username = $${params.length}`);
  }
  if (favorited) {
    params.push(favorited);
    conditions.push(`a.id IN (
      SELECT f.article_id FROM favorites f JOIN users fu ON fu.id = f.user_id
      WHERE fu.username = $${params.length}
    )`);
  }
  if (feedFor) {
    params.push(feedFor);
    conditions.push(`a.author_id IN (SELECT followed_id FROM follows WHERE follower_id = $${params.length})`);
  }

  params.push(limit);
  const limitIdx = params.length;
  params.push(offset);
  const offsetIdx = params.length;

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';

  const { rows } = await pool.query(
    `
    SELECT
      a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
      u.username AS author_username, u.bio AS author_bio, u.image AS author_image,
      COALESCE((SELECT array_agg(tag_name ORDER BY tag_name) FROM article_tags WHERE article_id = a.id), '{}') AS tag_list,
      (SELECT count(*) FROM favorites WHERE article_id = a.id) AS favorites_count,
      EXISTS (SELECT 1 FROM favorites WHERE article_id = a.id AND user_id = $1) AS favorited,
      EXISTS (SELECT 1 FROM follows WHERE follower_id = $1 AND followed_id = a.author_id) AS following,
      count(*) OVER() AS full_count
    FROM articles a
    JOIN users u ON u.id = a.author_id
    ${where}
    ORDER BY a.created_at DESC
    LIMIT $${limitIdx} OFFSET $${offsetIdx}
    `,
    params
  );

  return {
    articles: rows.map(mapArticleRow),
    articlesCount: rows.length ? Number(rows[0].full_count) : 0
  };
}

async function getArticleBySlug(slug, currentUserId) {
  const { rows } = await pool.query(
    `
    SELECT
      a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
      u.username AS author_username, u.bio AS author_bio, u.image AS author_image,
      COALESCE((SELECT array_agg(tag_name ORDER BY tag_name) FROM article_tags WHERE article_id = a.id), '{}') AS tag_list,
      (SELECT count(*) FROM favorites WHERE article_id = a.id) AS favorites_count,
      EXISTS (SELECT 1 FROM favorites WHERE article_id = a.id AND user_id = $2) AS favorited,
      EXISTS (SELECT 1 FROM follows WHERE follower_id = $2 AND followed_id = a.author_id) AS following
    FROM articles a
    JOIN users u ON u.id = a.author_id
    WHERE a.slug = $1
    `,
    [slug, currentUserId ?? null]
  );

  if (!rows.length) error(404, 'Article not found');
  return mapArticleRow(rows[0]);
}

async function createArticle(userId, { title, description, body, tagList = [] }) {
  const slug = slugify(title);

  const { rows } = await pool.query(
    `INSERT INTO articles (slug, title, description, body, author_id) VALUES ($1, $2, $3, $4, $5) RETURNING id`,
    [slug, title, description, body, userId]
  );
  const articleId = rows[0].id;

  for (const name of tagList) {
    await pool.query(`INSERT INTO tags (name) VALUES ($1) ON CONFLICT DO NOTHING`, [name]);
    await pool.query(
      `INSERT INTO article_tags (article_id, tag_name) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
      [articleId, name]
    );
  }

  return getArticleBySlug(slug, userId);
}

async function updateArticle(slug, { title, description, body }, currentUserId) {
  // Kept intentionally simple — this updates the article's own fields but not
  // its tagList. Extend it the same way createArticle handles tags if you need that.
  await pool.query(
    `UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description),
      body = COALESCE($4, body), updated_at = now() WHERE slug = $1`,
    [slug, title || null, description || null, body || null]
  );
  return getArticleBySlug(slug, currentUserId);
}

async function deleteArticle(slug) {
  await pool.query(`DELETE FROM articles WHERE slug = $1`, [slug]);
}

async function setFavorite(slug, userId, favorited) {
  const { rows } = await pool.query(`SELECT id FROM articles WHERE slug = $1`, [slug]);
  if (!rows.length) error(404, 'Article not found');

  if (favorited) {
    await pool.query(`INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [
      userId,
      rows[0].id
    ]);
  } else {
    await pool.query(`DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`, [userId, rows[0].id]);
  }

  return getArticleBySlug(slug, userId);
}

async function listTags() {
  const { rows } = await pool.query(`SELECT name FROM tags ORDER BY name`);
  return rows.map((r) => r.name);
}

// --- comments -------------------------------------------------------------

async function listComments(slug) {
  const { rows } = await pool.query(
    `SELECT c.id, c.body, c.created_at, c.updated_at,
            u.username AS author_username, u.bio AS author_bio, u.image AS author_image
     FROM comments c JOIN articles a ON a.id = c.article_id JOIN users u ON u.id = c.author_id
     WHERE a.slug = $1 ORDER BY c.created_at ASC`,
    [slug]
  );

  return rows.map((r) => ({
    id: r.id,
    body: r.body,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    author: { username: r.author_username, bio: r.author_bio ?? '', image: r.author_image }
  }));
}

async function addComment(slug, userId, body) {
  const { rows } = await pool.query(`SELECT id FROM articles WHERE slug = $1`, [slug]);
  if (!rows.length) error(404, 'Article not found');

  const { rows: inserted } = await pool.query(
    `INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) RETURNING id, body, created_at, updated_at`,
    [rows[0].id, userId, body]
  );
  const { rows: authorRows } = await pool.query(`SELECT username, bio, image FROM users WHERE id = $1`, [userId]);

  const c = inserted[0];
  return { id: c.id, body: c.body, createdAt: c.created_at, updatedAt: c.updated_at, author: authorRows[0] };
}

async function deleteComment(id) {
  await pool.query(`DELETE FROM comments WHERE id = $1`, [id]);
}

// --- profiles / follows -----------------------------------------------------

async function getProfile(username, currentUserId) {
  const { rows } = await pool.query(
    `SELECT u.username, u.bio, u.image,
            EXISTS (SELECT 1 FROM follows WHERE follower_id = $2 AND followed_id = u.id) AS following
     FROM users u WHERE u.username = $1`,
    [username, currentUserId ?? null]
  );
  if (!rows.length) error(404, 'User not found');
  return rows[0];
}

async function setFollow(username, followerId, follow) {
  const { rows } = await pool.query(`SELECT id FROM users WHERE username = $1`, [username]);
  if (!rows.length) error(404, 'User not found');

  if (follow) {
    await pool.query(`INSERT INTO follows (follower_id, followed_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [
      followerId,
      rows[0].id
    ]);
  } else {
    await pool.query(`DELETE FROM follows WHERE follower_id = $1 AND followed_id = $2`, [followerId, rows[0].id]);
  }

  return getProfile(username, followerId);
}

// --- users ------------------------------------------------------------------

async function login(email, password) {
  const { rows } = await pool.query(`SELECT * FROM users WHERE email = $1`, [email]);
  if (!rows.length || !(await bcrypt.compare(password, rows[0].password_hash))) {
    return { errors: { 'email or password': ['is invalid'] } };
  }
  return { user: toUserJson(rows[0]) };
}

async function register(username, email, password) {
  try {
    const password_hash = await bcrypt.hash(password, 10);
    const { rows } = await pool.query(
      `INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING *`,
      [username, email, password_hash]
    );
    return { user: toUserJson(rows[0]) };
  } catch (err) {
    if (err.code === '23505') return { errors: { 'username or email': ['is already taken'] } };
    throw err;
  }
}

async function updateUser(userId, { username, email, password, image, bio }) {
  const password_hash = password ? await bcrypt.hash(password, 10) : null;
  const { rows } = await pool.query(
    `UPDATE users SET username = COALESCE($2, username), email = COALESCE($3, email),
      password_hash = COALESCE($4, password_hash), image = COALESCE($5, image), bio = COALESCE($6, bio)
     WHERE id = $1 RETURNING *`,
    [userId, username || null, email || null, password_hash, image || null, bio || null]
  );
  return { user: toUserJson(rows[0]) };
}

// --- the router ---------------------------------------------------------
// Everything above is the "database" half. Everything below just maps the
// same (method, path) pairs the app already calls onto those functions —
// this is the part that keeps the four exports below a drop-in replacement.

async function send({ method, path, data, token }) {
  const [route, query = ''] = path.split('?');
  const params = new URLSearchParams(query);
  const segments = route.split('/').filter(Boolean);
  const currentUserId = decodeToken(token);

  if (method === 'GET' && route === 'tags') {
    return { tags: await listTags() };
  }

  if (method === 'GET' && (route === 'articles' || route === 'articles/feed')) {
    return listArticles(
      {
        limit: Number(params.get('limit') ?? 20),
        offset: Number(params.get('offset') ?? 0),
        tag: params.get('tag') || undefined,
        author: params.get('author') || undefined,
        favorited: params.get('favorited') || undefined,
        feedFor: route === 'articles/feed' ? currentUserId : undefined
      },
      currentUserId
    );
  }

  if (method === 'POST' && route === 'articles') {
    if (!currentUserId) error(401);
    return { article: await createArticle(currentUserId, data.article) };
  }

  if (segments[0] === 'articles' && segments.length === 2) {
    const slug = segments[1];
    if (method === 'GET') return { article: await getArticleBySlug(slug, currentUserId) };
    if (method === 'PUT') {
      if (!currentUserId) error(401);
      return { article: await updateArticle(slug, data.article, currentUserId) };
    }
    if (method === 'DELETE') {
      if (!currentUserId) error(401);
      await deleteArticle(slug);
      return {};
    }
  }

  if (segments[0] === 'articles' && segments[2] === 'comments') {
    const slug = segments[1];
    if (method === 'GET') return { comments: await listComments(slug) };
    if (method === 'POST') {
      if (!currentUserId) error(401);
      return { comment: await addComment(slug, currentUserId, data.comment.body) };
    }
    if (method === 'DELETE') {
      if (!currentUserId) error(401);
      await deleteComment(segments[3]);
      return {};
    }
  }

  if (segments[0] === 'articles' && segments[2] === 'favorite') {
    if (!currentUserId) error(401);
    return { article: await setFavorite(segments[1], currentUserId, method === 'POST') };
  }

  if (segments[0] === 'profiles' && segments.length === 2) {
    return { profile: await getProfile(segments[1], currentUserId) };
  }

  if (segments[0] === 'profiles' && segments[2] === 'follow') {
    if (!currentUserId) error(401);
    return { profile: await setFollow(segments[1], currentUserId, method === 'POST') };
  }

  if (method === 'POST' && route === 'users/login') {
    return login(data.user.email, data.user.password);
  }

  if (method === 'POST' && route === 'users') {
    return register(data.user.username, data.user.email, data.user.password);
  }

  if (method === 'PUT' && route === 'user') {
    if (!currentUserId) error(401);
    return updateUser(currentUserId, data.user);
  }

  error(404, `no local handler for ${method} ${route}`);
}

export function get(path, token) {
  return send({ method: 'GET', path, token });
}
export function del(path, token) {
  return send({ method: 'DELETE', path, token });
}
export function post(path, data, token) {
  return send({ method: 'POST', path, data, token });
}
export function put(path, data, token) {
  return send({ method: 'PUT', path, data, token });
}
