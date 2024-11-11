-- Create the user table
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    group_id INTEGER,
    username VARCHAR(255) UNIQUE,
    password VARCHAR(255),
    home VARCHAR(255),
    nickname VARCHAR(255) DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT NULL
);

-- Set the auto-increment starting value to 1001
ALTER SEQUENCE users_id_seq RESTART WITH 1001;

-- Create trigger function to update 'updated_at'
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
   NEW.updated_at = NOW();
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger on 'users' table
CREATE TRIGGER update_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION update_modified_column();
