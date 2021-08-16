# create databases
CREATE DATABASE IF NOT EXISTS `fuelrod`;

CREATE DATABASE IF NOT EXISTS `blog`;

# create root user and grant rights
GRANT ALL PRIVILEGES ON fuelrod.* TO 'fuelrod'@'%';
