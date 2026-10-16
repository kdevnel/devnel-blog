-- Made-up data for the sanitiser tests. Nothing here comes from production: the addresses use
-- reserved or invented domains, the IPs are documentation ranges, and the "key" is a stand-in
-- (the PEM marker is assembled with CONCAT so no key-like text sits in this file).
SET NAMES utf8mb4;

CREATE TABLE wp_users (
  ID bigint unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_login varchar(60) NOT NULL DEFAULT '',
  user_pass varchar(255) NOT NULL DEFAULT '',
  user_nicename varchar(50) NOT NULL DEFAULT '',
  user_email varchar(100) NOT NULL DEFAULT '',
  user_url varchar(100) NOT NULL DEFAULT '',
  user_activation_key varchar(255) NOT NULL DEFAULT '',
  display_name varchar(250) NOT NULL DEFAULT ''
);
INSERT INTO wp_users (user_login, user_pass, user_nicename, user_email, user_url, user_activation_key, display_name) VALUES
  ('alice', 'fake-hash-alice', 'alice', 'alice@corp.example.org', 'https://alice.example.org', 'fake-activation-key', 'Alice A'),
  ('bob', 'fake-hash-bob', 'bob', 'bob@mail.invalid', '', '', 'Bob B');

CREATE TABLE wp_usermeta (
  umeta_id bigint unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id bigint unsigned NOT NULL DEFAULT 0,
  meta_key varchar(255) DEFAULT NULL,
  meta_value longtext
);
INSERT INTO wp_usermeta (user_id, meta_key, meta_value) VALUES
  (1, 'nickname', 'alice'),
  (1, 'description', 'Write to me at alice.bio@corp.example.org any time'),
  (1, 'session_tokens', 'a:1:{s:4:"fake";a:0:{}}'),
  (1, 'magic_sig_private_key', 'fake'),
  (1, 'magic_sig_public_key', 'fake'),
  (1, 'jetpack_account_protection_recent_password_hashes', 'fake'),
  (1, '_application_passwords', 'fake'),
  (1, 'my_private_note', 'fake'),
  (2, 'service_API_TOKEN', 'fake'),
  (2, 'x_secret_y', 'fake'),
  (2, 'keypair', CONCAT('-----BE', 'GIN FAKE-----')),
  (2, 'locale', 'en_GB');

CREATE TABLE wp_comments (
  comment_ID bigint unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
  comment_post_ID bigint unsigned NOT NULL DEFAULT 0,
  comment_author tinytext NOT NULL,
  comment_author_email varchar(100) NOT NULL DEFAULT '',
  comment_author_url varchar(200) NOT NULL DEFAULT '',
  comment_author_IP varchar(100) NOT NULL DEFAULT '',
  comment_content text NOT NULL,
  comment_agent varchar(255) NOT NULL DEFAULT ''
);
INSERT INTO wp_comments (comment_post_ID, comment_author, comment_author_email, comment_author_url, comment_author_IP, comment_content, comment_agent) VALUES
  (1, 'Carol', 'carol@elsewhere.example.net', 'https://carol.example.net', '203.0.113.7', 'Nice post, version 2.0 is out', 'Mozilla/5.0 (fake)'),
  (1, 'Dave', 'dave@elsewhere.example.net', '', '2001:db8::1', 'Agreed', 'Mozilla/5.0 (fake)');

CREATE TABLE wp_commentmeta (
  meta_id bigint unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
  comment_id bigint unsigned NOT NULL DEFAULT 0,
  meta_key varchar(255) DEFAULT NULL,
  meta_value longtext
);
INSERT INTO wp_commentmeta (comment_id, meta_key, meta_value) VALUES
  (1, 'akismet_as_submitted', 'a:2:{s:5:"email";s:26:"carol@elsewhere.example.net";s:2:"ip";s:11:"203.0.113.7";}'),
  (1, 'ip_only', '198.51.100.9'),
  (2, 'v6_only', '2001:db8:0:0:0:0:0:2'),
  (2, 'akismet_result', 'false');

CREATE TABLE wp_options (
  option_id bigint unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
  option_name varchar(191) NOT NULL DEFAULT '',
  option_value longtext NOT NULL,
  autoload varchar(20) NOT NULL DEFAULT 'yes'
);
INSERT INTO wp_options (option_name, option_value) VALUES
  ('siteurl', 'https://devnel.blog'),
  ('home', 'https://devnel.blog'),
  ('blogname', 'Test blog'),
  ('admin_email', 'owner@corp.example.org'),
  ('new_admin_email', 'owner@corp.example.org'),
  ('activitypub_application_keypair', 'fake'),
  ('activitypub_keypair_for_1', 'fake'),
  ('mwp_worker_key', 'fake'),
  ('_worker_nonce', 'fake'),
  ('friends_private_rss_key', 'fake'),
  ('friends_codeword', 'fake'),
  ('mailserver_login', 'fake'),
  ('mailserver_pass', 'fake'),
  ('mailserver_url', 'fake'),
  ('post_by_email_address1', 'fake'),
  ('postman_options', 'fake'),
  ('postman_state', 'fake'),
  ('postman_rat', 'fake'),
  ('post_smtp_webhook_urls', 'fake'),
  ('wordpress_api_key', 'fake'),
  ('crowdsignal_api_key', 'fake'),
  ('updraft_s3', 'fake'),
  ('updraft_sftp', 'fake'),
  ('updraft_interval', 'daily'),
  ('updraftplus-addons_siteid', 'fake'),
  ('tantan_wordpress_s3', 'fake'),
  ('as3cf_constant_AS3CF_SETTINGS', 'fake'),
  ('fs_accounts', 'fake'),
  ('jetpack_private_options', 'fake'),
  ('nonce_key', 'fake'),
  ('nonce_salt', 'fake'),
  ('auth_key', 'fake'),
  ('secure_auth_key', 'fake'),
  ('logged_in_key', 'fake'),
  ('logged_in_salt', 'fake'),
  ('recovery_keys', 'fake'),
  ('_transient_feed_abc', 'cached'),
  ('_site_transient_update_core', 'cached'),
  ('some_plugin_blob', CONCAT('-----BE', 'GIN FAKE-----')),
  ('blogdescription', 'Just another test');

CREATE TABLE wp_posts (
  ID bigint unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
  post_title text NOT NULL,
  post_content longtext NOT NULL,
  post_status varchar(20) NOT NULL DEFAULT 'publish',
  post_type varchar(20) NOT NULL DEFAULT 'post'
);
INSERT INTO wp_posts (post_title, post_content, post_status, post_type) VALUES
  ('Hello', '<!-- wp:paragraph --><p>Hello there, 3.14 is pi</p><!-- /wp:paragraph -->', 'publish', 'post'),
  ('About', '<!-- wp:paragraph --><p>About page</p><!-- /wp:paragraph -->', 'publish', 'page');

CREATE TABLE wp_post_smtp_logs (id int PRIMARY KEY, to_header text);
INSERT INTO wp_post_smtp_logs VALUES (1, 'someone@corp.example.org');
CREATE TABLE wp_post_smtp_logmeta (id int PRIMARY KEY, v text);
INSERT INTO wp_post_smtp_logmeta VALUES (1, 'fake');
CREATE TABLE wp_redirection_404 (id int PRIMARY KEY, url text);
INSERT INTO wp_redirection_404 VALUES (1, '/missing');
CREATE TABLE wp_redirection_logs (id int PRIMARY KEY, ip varchar(45));
INSERT INTO wp_redirection_logs VALUES (1, '203.0.113.50');
CREATE TABLE wp_jetpack_waf_blocklog (id int PRIMARY KEY, v text);
INSERT INTO wp_jetpack_waf_blocklog VALUES (1, 'fake');
CREATE TABLE wp_zbs_contacts (id int PRIMARY KEY, email varchar(100));
INSERT INTO wp_zbs_contacts VALUES (1, 'lead@corp.example.org');
CREATE TABLE wp_zbs_invoices (id int PRIMARY KEY, total int);
INSERT INTO wp_zbs_invoices VALUES (1, 100);

-- Kept: the redirects must survive.
CREATE TABLE wp_redirection_items (id int PRIMARY KEY, url text, action_data text);
INSERT INTO wp_redirection_items VALUES (1, '/old', '/new');
CREATE TABLE wp_redirection_groups (id int PRIMARY KEY, name text);
INSERT INTO wp_redirection_groups VALUES (1, 'Redirections');
