# create databases
CREATE DATABASE IF NOT EXISTS `fuelrod`;

# create root user and grant rights
GRANT ALL PRIVILEGES ON fuelrod.* TO 'fuelrod'@'%';
