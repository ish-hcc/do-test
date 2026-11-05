#!/bin/bash
# RDBMS 수집 확인용 MySQL (OS 패키지). root 로 실행한다.
# 수집 확인용 스키마 cmtest 와 표 하나를 만든다.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y install mysql-server
sed -i -E 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl enable --now mysql
systemctl restart mysql
mysql -uroot -e "CREATE DATABASE IF NOT EXISTS cmtest; CREATE TABLE IF NOT EXISTS cmtest.items (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(64)); INSERT INTO cmtest.items(name) VALUES ('honeybee');"
mysql -uroot -N -e "SELECT VERSION();"
ss -ltn 'sport = :3306'
