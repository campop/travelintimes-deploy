#!/bin/bash
# Installation
# Written for Ubuntu 22.04 LTS Server


## Stage 1: Boilerplate script setup

echo "#	Install travelintimes"

# Ensure this script is run as root
if [ "$(id -u)" != "0" ]; then
	echo "# This script must be run as root." 1>&2
	exit 1
fi

# Bomb out if something goes wrong
set -e

# Lock directory
lockdir=/var/lock/travelintimes
mkdir -p $lockdir

# Set a lock file; see: https://stackoverflow.com/questions/7057234/bash-flock-exit-if-cant-acquire-lock/7057385
(
	flock -n 9 || { echo '#	An installation is already running' ; exit 1; }


# Get the script directory see: https://stackoverflow.com/a/246128/180733
# The multi-line method of geting the script directory is needed to enable the script to be called from elsewhere.
SOURCE="${BASH_SOURCE[0]}"
DIR="$( dirname "$SOURCE" )"
while [ -h "$SOURCE" ]
do
	SOURCE="$(readlink "$SOURCE")"
	[[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
	DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
SCRIPTDIRECTORY=$DIR


## Main body

# Update sources and packages
apt-get -y update
apt-get -y upgrade
apt-get -y dist-upgrade
apt-get -y autoremove

# General packages, useful while developing
apt-get install -y unzip nano man-db bzip2 dnsutils
apt-get install -y mlocate

# General packages, required for deployment
apt-get install -y git wget curl


## Stage 2: Conversion software

# Define path containing all local software; can be specified as a script argument, or the default will be used
softwareRoot=${1:-/var/www/travelintimes}

# Add user and group who will own the files
adduser --gecos "" travelintimes || echo "The travelintimes user already exists"
addgroup travelintimes || echo "The travelintimes group already exists"

# Create the directory
mkdir -p $softwareRoot
chown travelintimes.travelintimes $softwareRoot

# GDAL/ogr2ogr
apt-get install -y gdal-bin

# ogr2osm, for conversion of shapefiles to .osm
# See: https://wiki.openstreetmap.org/wiki/Ogr2osm
# See: https://github.com/roelderickx/ogr2osm
# Usage: ogr2osm my-shapefile.shp [-t my-translation-file.py]
apt-get install -y python3 python3-pip
pip install --upgrade ogr2osm

# Omsosis, for pre-processing of .osm files
# See: https://wiki.openstreetmap.org/wiki/Osmosis/Installation
apt-get install -y osmosis

# # osmconvert, for merging .osm files
# apt-get -y install osmctools

# Install modern version of Node.js (Ubuntu repo version is old), which includes npm
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs

# Conversion to GeoJSON
npm install -g osmtogeojson
npm install -g ndjson-cli
npm install -g geojson-mend
npm install -g geojson-precision
apt-get install -y jq



## Stage 3: Webserver software

# Webserver (Apache 2.4)
apt-get install -y apache2
a2enmod rewrite
apt-get install -y php php-cli php-xml
apt-get install -y libapache2-mod-php
a2enmod macro
a2enmod headers

# Disable Apache logrotate, as this loses log entries for stats purposes
if [ -f /etc/logrotate.d/apache2 ]; then
	mv /etc/logrotate.d/apache2 /etc/logrotate.d-apache2.disabled
fi



## Stage 4: Front-end software

# Create website area
websiteDirectory=$softwareRoot/travelintimes
if [ ! -d "$websiteDirectory/" ]; then
	mkdir "$websiteDirectory/"
	git clone https://github.com/campop/travelintimes.git "$websiteDirectory/"
	git config --global --add safe.directory "$websiteDirectory"
	cp -p "${websiteDirectory}/htdocs/.config.js.template" "${websiteDirectory}/htdocs/.config.js"
else
	echo "Updating travelintimes repo ..."
	cd "$websiteDirectory/"
	git pull
	echo "... done"
fi
chown -R travelintimes.travelintimes "$websiteDirectory/"
chmod -R g+w "$websiteDirectory/"
find "$websiteDirectory/" -type d -exec chmod g+s {} \;
cp -p "$websiteDirectory/htdocs/controlpanel/index.html.template" "$websiteDirectory/htdocs/controlpanel/index.html"

# Add routing UI library
websiteDirectory=$softwareRoot/routing-ui
if [ ! -d "$websiteDirectory/" ]; then
	mkdir "$websiteDirectory/"
	git clone https://github.com/cyclestreets/routing-ui "$websiteDirectory/"
	git config --global --add safe.directory "$websiteDirectory"
else
	echo "Updating routing-ui repo ..."
	cd "$websiteDirectory/"
	git pull
	echo "... done"
fi
chown -R travelintimes.travelintimes "$websiteDirectory/"
chmod -R g+w "$websiteDirectory/"
find "$websiteDirectory/" -type d -exec chmod g+s {} \;

# Ensure the GeoJSON directory is writable
chown -R www-data "$websiteDirectory/htdocs/geojson/"

# Ensure the configurations directories are writable by the webserver
chown www-data "${websiteDirectory}/configuration"
chown www-data "${websiteDirectory}/configuration/mapnikstylesheet"
chown www-data "${websiteDirectory}/configuration/routingprofiles"
chown www-data "${websiteDirectory}/configuration/turns"
chown www-data "${websiteDirectory}/configuration/tagtransform"
chown www-data "${websiteDirectory}/configuration/mapnikstylesheet/archive"
chown www-data "${websiteDirectory}/configuration/routingprofiles/archive"
chown www-data "${websiteDirectory}/configuration/turns/archive"
chown www-data "${websiteDirectory}/configuration/tagtransform/archive"

# Ensure the configuration files are writable by the webserver
chown www-data "${websiteDirectory}/configuration/tagtransform/tagtransform.xml"
chown www-data "${websiteDirectory}/configuration/mapnikstylesheet/mapnikstylesheet.xml"
chown www-data "${websiteDirectory}/configuration/routingprofiles/profile-"*
chown www-data "${websiteDirectory}/configuration/turns/turns-"*

# Ensure the upload export files are writable by the webserver
chown www-data "${websiteDirectory}/exports"

# Ensure the build directory is writable by the webserver
chown www-data "${websiteDirectory}/enginedata/"

# Link in Apache VirtualHost
if [ ! -f /etc/apache2/sites-available/travelintimes.conf ]; then
	cp -p $SCRIPTDIRECTORY/apache.conf /etc/apache2/sites-available/travelintimes.conf
	sed -i "s|/var/www/travelintimes|${softwareRoot}|g" /etc/apache2/sites-available/travelintimes.conf
	a2ensite travelintimes
fi


## Stage 5: Routing engine and isochrones

# OSRM routing engine
# See: https://github.com/Project-OSRM/osrm-backend/wiki/Building-OSRM
# See: https://github.com/Project-OSRM/osrm-backend/wiki/Building-on-Ubuntu
# See: https://github.com/Project-OSRM/osrm-backend/wiki/Running-OSRM
osrmBackendDirectory=$softwareRoot/osrm-backend
osrmVersion=5.27.1
if [ ! -f "${osrmBackendDirectory}/build/osrm-extract" ]; then
	# Get the release
	cd $softwareRoot/
	mkdir "$osrmBackendDirectory"
	chown -R travelintimes.travelintimes "$osrmBackendDirectory"
	wget -P /tmp/ "https://github.com/Project-OSRM/osrm-backend/archive/v${osrmVersion}.tar.gz"
	sudo -H -u travelintimes bash -c "tar -xvzf /tmp/v${osrmVersion}.tar.gz -C ${osrmBackendDirectory}/ --strip-components=1"
	rm "/tmp/v${osrmVersion}.tar.gz"
	cd "$osrmBackendDirectory/"
	chown www-data profiles/
	mkdir -p build
	chown -R travelintimes.travelintimes "${osrmBackendDirectory}/build/"
	# Get build dependencies
	apt-get install -y build-essential git cmake pkg-config doxygen libboost-all-dev libtbb-dev lua5.2 liblua5.2-dev libluabind-dev libstxxl-dev libstxxl1v5 libxml2 libxml2-dev libosmpbf-dev libbz2-dev libzip-dev libprotobuf-dev
	# Build
	cd build
	sudo -H -u travelintimes bash -c 'cmake .. -DCMAKE_BUILD_TYPE=Release'
	sudo -H -u travelintimes bash -c "cmake --build ."
fi
chmod -R g+w "$osrmBackendDirectory/"
find "$osrmBackendDirectory/" -type d -exec chmod g+s {} \;


if [ 1 -eq 0 ]; then

# nvm; install then load immediately; see: https://github.com/nvm-sh/nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm

# Isochrones, using Galton: https://github.com/urbica/galton
# Binds against OSRM 5.17.2; see: https://github.com/urbica/galton/issues/231#issuecomment-707938664
# Note that 8.0.0 does not work - using "8" will give v8.17.0, which works
nvm install 8
nvm use 8
cd "$softwareRoot/"
set +e	# Remove stop-on-error
npm install galton@v5.17.2
set -e	# Restore stop-on-error
chown -R travelintimes.travelintimes node_modules/
rm package-lock.json

fi


# Add firewall
# Check status using: sudo ufw status verbose
apt-get -y install ufw
ufw logging low
#ufw --force reset
ufw --force enable
ufw default deny
ufw allow ssh
ufw allow http
ufw allow https
# Permit routing engines from port 5000
ufw allow from 127.0.0.1 to any port 5000
ufw allow from 127.0.0.1 to any port 5001
ufw allow from 127.0.0.1 to any port 5002
ufw allow from 127.0.0.1 to any port 5003
# Permit isochrone engines from port 4000
ufw allow from 127.0.0.1 to any port 4000
ufw allow from 127.0.0.1 to any port 4001
ufw allow from 127.0.0.1 to any port 4002
ufw allow from 127.0.0.1 to any port 4003
ufw reload
ufw status verbose
# Set UFW logging to be done only into /var/log/ufw.log rather than into /var/log/syslog
sed -i 's/#\& ~/\& stop/g' /etc/rsyslog.d/20-ufw.conf
service rsyslog restart

# Enable Apache-commenced OSRM process to log to a folder
chown www-data "${websiteDirectory}/logs-osrm/"


## Stage 6: HTTPS support


# Install certbot (Let's Encrypt)
apt-get install -y certbot

# Issue certificate
domainName=www.travelintimes.org
if [ ! -f "/etc/letsencrypt/live/${domainName}/fullchain.pem" ]; then
	email="campop@"
	email+="geog.cam.ac.uk"
	set +e  # Remove stop-on-error
	certbot --agree-tos --no-eff-email certonly --keep-until-expiring --webroot -w $softwareRoot/travelintimes/htdocs/ --email $email -d "${domainName}" -d travelintimes.org
	set -e  # Restore stop-on-error
fi

# Enable SSL in Apache
a2enmod ssl

# Enable proxing, as osrm-routed can only serve HTTP, not HTTPS
a2enmod proxy proxy_http

# Restart Apache
service apache2 restart


## Stage 7: Tile rendering
if [ 1 -eq 0 ]; then
# Install mapnik; see: https://switch2osm.org/serving-tiles/manually-building-a-tile-server-20-04-lts/ and https://wiki.openstreetmap.org/wiki/User:SomeoneElse/Ubuntu_1604_tileserver_load#Mapnik
apt-get install -y libboost-all-dev git tar unzip wget bzip2 build-essential autoconf libtool libxml2-dev libgeos-dev libgeos++-dev libpq-dev libbz2-dev libproj-dev munin-node munin protobuf-c-compiler libfreetype6-dev libtiff5-dev libicu-dev libgdal-dev libcairo2-dev libcairomm-1.0-dev apache2 apache2-dev libagg-dev liblua5.2-dev ttf-unifont lua5.1 liblua5.1-0-dev
fi


# Update file search index
updatedb

# Report completion
echo "#	Installation completed"

# Remind the user to update the website config file
echo "Please set your API keys by editing the website config file at ${websiteDirectory}/htdocs/.config.js"

# Give a link to the control panel
echo "Please upload data and start the routing at https://${domainName}/controlpanel/"
echo "If you have existing data files, copy them to the exports folder at $softwareRoot/travelintimes/exports/"

# Remove the lock file - ${0##*/} extracts the script's basename
) 9>$lockdir/${0##*/}

# End of file
