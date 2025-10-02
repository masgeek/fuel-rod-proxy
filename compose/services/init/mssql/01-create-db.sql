-- Create database if it doesn't exist
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'school')
BEGIN
    CREATE DATABASE school;
END
GO
-- Use the newly created database