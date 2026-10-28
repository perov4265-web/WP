# Неизвестный пароль root в MySQL 8.4

`install.sh` делает это сам (`--db-root-reset` или ответ «да» на вопрос).
Ниже — то же руками, если скрипт под рукой нет. Проверено на MySQL 8.4.11,
подходит для 8.0 и MariaDB.

## Сначала — может, пароль и не нужен

```bash
sudo mysql                                        # Ubuntu: root входит по сокету
sudo mysql --defaults-file=/etc/mysql/debian.cnf  # служебная учётка Debian/Ubuntu
sudo grep 'temporary password' /var/log/mysqld.log /var/log/mysql/error.log
```

Временный пароль из журнала (так ставит MySQL репозиторий Oracle) годится
только для смены пароля:

```bash
mysql -u root -p --connect-expired-password \
  -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'НовыйПароль';"
```

## Сброс

```bash
sudo systemctl stop mysql
sudo mkdir -p /run/mysqld && sudo chown mysql:mysql /run/mysqld
sudo mysqld --user=mysql --skip-grant-tables --skip-networking &
sleep 5
mysql -u root -e "FLUSH PRIVILEGES;
  ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'НовыйПароль';"
mysqladmin -u root shutdown
sudo systemctl start mysql
```

## Почему «рецепты из интернета» на 8.4 не работают

| Что пробуют | Что получается в 8.4 | Как надо |
|---|---|---|
| `IDENTIFIED WITH mysql_native_password` | `Plugin 'mysql_native_password' is not loaded` — в 8.4 он выключен по умолчанию | `caching_sha2_password` (PHP 7.4+ его понимает) |
| `ALTER USER` сразу после `--skip-grant-tables` | `The MySQL server is running with the --skip-grant-tables option so it cannot execute this statement` | сначала `FLUSH PRIVILEGES;` |
| `UPDATE mysql.user SET authentication_string=PASSWORD(...)` | функции `PASSWORD()` нет с 8.0 | `ALTER USER` |
| `systemctl set-environment MYSQLD_OPTS=--skip-grant-tables` | у пакета Ubuntu юнит эту переменную не читает (читает только юнит Oracle) | запускать `mysqld` руками, как выше |
| `--skip-grant-tables` без `--skip-networking` | в 8.x сеть и так отключается, но явно — надёжнее: сервер без паролей не должен слушать порт | оставить `--skip-networking` |

После сброса скрипт кладёт пароль в `/root/.my.cnf` (права 600), чтобы
`sudo mysql` и дальше входил без вопросов.
