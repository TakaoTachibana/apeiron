-- 1. データベースの作成
CREATE DATABASE IF NOT EXISTS apeiron_db;
USE apeiron_db;

-- 2. テーブルの作成
CREATE TABLE IF NOT EXISTS attractors (
	id VARCHAR(36) PRIMARY KEY,
	formula_latex TEXT NOT NULL,
	r_squared FLOAT NOT NULL,
	is_stable BOOLEAN NOT NULL,
	created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 3. root ユーザーの TCP パスワード認証設定 (localhost, 127.0.0.1, %)
ALTER USER 'root'@'localhost' IDENTIFIED BY 'password';

CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY 'password';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'password';

ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY 'password';
ALTER USER 'root'@'%' IDENTIFIED BY 'password';

-- 4. 全権限の付与
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
