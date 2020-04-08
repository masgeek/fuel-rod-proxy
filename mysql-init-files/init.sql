# create databases
CREATE DATABASE IF NOT EXISTS `fuelrod`;
CREATE DATABASE IF NOT EXISTS `tsobu_site`;

# create root user and grant rights
GRANT ALL PRIVILEGES ON fuelrod.* TO 'fuelrod'@'%';
