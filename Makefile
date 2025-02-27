PYTHON=$(shell which python)
IMAGE_NAME=marketplace-ubi7
.PHONY: build

TOPDIR=$(shell pwd)
PYDIR=marketplace
STATIC=staticfiles

# OC Params
OC_TEMPLATE_DIR = $(TOPDIR)/openshift
OC_PARAM_DIR = $(OC_TEMPLATE_DIR)/parameters

# required OpenShift template parameters
NAME = 'marketplace'
NAMESPACE = 'marketplace'

# OC dev variables
OC_SOURCE=registry.access.redhat.com/openshift3/ose
OC_VERSION=v3.9
OC_DATA_DIR=${HOME}/.oc/openshift.local.data

OS := $(shell uname)
ifeq ($(OS),Darwin)
	PREFIX	=
else
	PREFIX	= sudo
endif

help:
	@echo "Please use \`make <target>' where <target> is one of:"
	@echo ""
	@echo "--- General Commands ---"
	@echo "clean                    clean the project directory of any scratch files, bytecode, logs, etc."
	@echo "help                     show this message"
	@echo ""
	@echo "--- Commands using local services ---"
	@echo "server-migrate           run migrations against database"
	@echo "serve                    run the Django server locally"
	@echo "lint                     to run linters on code"
	@echo "unittest                 run the unit tests"
	@echo "test-coverage            run the test coverage"
	@echo "server-static            collect static files to host"
	@echo "start-db                 start postgres db"
	@echo "clean-db                 remove postgres db"
	@echo "reinit-db                remove db and start a new one"
	@echo "manifest                 create/update manifest for product security"
	@echo "check-manifest           check that the manifest is up to date"
	@echo "scan_project             run security scan"
	@echo ""
	@echo "--- Commands using an OpenShift Cluster ---"
	@echo "oc-clean                 stop openshift cluster & remove local config data"
	@echo "oc-up                    initialize an openshift cluster"
	@echo "oc-down                  stop app & openshift cluster"
	@echo "oc-create-secret         create secret in an initialized openshift cluster"
	@echo "oc-login-admin           login to openshift as admin"
	@echo "oc-login-developer       login to openshift as developer"
	@echo "oc-server-migrate        run migrations"
	@echo "oc-delete-marketplace         delete the marketplace project, app, and data"
	@echo "oc-delete-marketplace-data    delete the marketplace app and data"
	@echo "oc-refresh               apply template changes to openshift dedicated"
	@echo ""
	@echo "--- Commands for local development ---"
	@echo "local-dev-up                                bring up marketplace with all required services"
	@echo "local-dev-down                              bring down marketplace with all required services"
	@echo "sample-data                                 ready sample data for upload to the ingress service"
	@echo "local-upload-data file=<path/to/file>       upload data to local ingress service for marketplace processing"
	@echo "upload-data file=<path/to/file>       	   upload data to ingress service for marketplace processing"
	@echo ""

clean:
	git clean -fdx -e .idea/ -e *env/ $(PYDIR)/db.sqlite3
	rm -rf marketplace/static
	rm -rf temp/

lint:
	pre-commit run --all-files

collect-static:
	$(PYTHON) $(PYDIR)/manage.py collectstatic --no-input

server-makemigrations:
	$(PYTHON) $(PYDIR)/manage.py makemigrations api --settings config.settings.local

server-migrate:
	DJANGO_READ_DOT_ENV_FILE=True $(PYTHON) $(PYDIR)/manage.py migrate -v 3

serve:
	DJANGO_READ_DOT_ENV_FILE=True $(PYTHON) $(PYDIR)/manage.py runserver 127.0.0.1:8001

gunicorn:
	DJANGO_READ_DOT_ENV_FILE=True gunicorn "config.wsgi" -c "./marketplace/config/gunicorn.py" --chdir=./marketplace --bind=127.0.0.1:8001 --access-logfile=-

server-static:
	mkdir -p ./marketplace/static/client
	$(PYTHON) marketplace/manage.py collectstatic --settings config.settings.local --no-input

server-init: server-migrate server-static

unittest:
	$(PYTHON) $(PYDIR)/manage.py test $(PYDIR) -v 2 --noinput --keepdb

test-coverage:
	tox -e py36 --

build:
	docker build -t $(IMAGE_NAME) .

clean-db:
	$(PREFIX) rm -rf $(TOPDIR)/pg_data
	make compose-down

start-db:
	docker-compose up -d db

compose-down:
	docker-compose down

wait-db:
	sleep 10

reinit-db: compose-down clean-db start-db wait-db server-migrate

local-dev-up:
	./scripts/bring_up_all.sh
	clear

local-dev-down:
	cd ../insights-ingress-go;docker-compose -f development/local-dev-start.yml down
	docker-compose down
	osascript -e 'quit app "iTerm"' | true

local-upload-data:
	curl -vvvv -F "upload=@$(file);type=application/vnd.redhat.mkt.$(basename $(basename $(notdir $(file))))+tgz" \
		-H "x-rh-identity: eyJpZGVudGl0eSI6IHsiYWNjb3VudF9udW1iZXIiOiAiMTIzNDUiLCAiaW50ZXJuYWwiOiB7Im9yZ19pZCI6ICI1NDMyMSJ9fX0=" \
		-H "x-rh-request_id: testtesttest" \
		localhost:8080/api/ingress/v1/upload

sample-data:
	mkdir -p temp/reports
	mkdir -p temp/old_reports_temp
	tar -xvzf sample.tar.gz -C temp/old_reports_temp
	python scripts/change_uuids.py
	@NEW_FILENAME="sample_data_ready_$(shell date +%s).tar.gz"; \
	cd temp; COPYFILE_DISABLE=1 tar -zcvf $$NEW_FILENAME reports; \
	echo ""; \
	echo "The updated report was written to" temp/$$NEW_FILENAME; \
	echo ""; \
	rm -rf reports; \
	rm -rf old_reports_temp

upload-data:
	curl -vvvv -F "file=@$(file);type=application/vnd.redhat.mkt.tar+tgz" \
		$(INGRESS_URL) \
		-u $(RH_USERNAME):$(RH_PASSWORD)

upload-proxy-data:
	curl -vvvv -F "file=@$(file);type=application/vnd.redhat.mkt.tar+tgz" \
		--proxy ${UPLOAD_PROXY}  \
		$(INGRESS_URL) \
		-u $(RH_USERNAME):$(RH_PASSWORD)

manifest:
	python scripts/create_manifest.py

check-manifest:
	./.travis/check_manifest.sh

scan_project:
	./sonarqube.sh

# Local commands for working with OpenShift
oc-up:
	oc cluster up \
		--image=$(OC_SOURCE) \
		--version=$(OC_VERSION) \
		--host-data-dir=$(OC_DATA_DIR) \
		--use-existing-config=true
	sleep 60

oc-down:
	oc cluster down

oc-clean: oc-down
	$(PREFIX) rm -rf $(OC_DATA_DIR)

oc-login-admin:
	oc login -u system:admin

oc-login-developer:
	oc login -u developer -p developer --insecure-skip-tls-verify

oc-project:
	oc new-project ${NAMESPACE}
	oc project ${NAMESPACE}

oc-delete-marketplace-data:
	oc delete all -l app=marketplace
	oc delete persistentvolumeclaim marketplace-db
	oc delete configmaps marketplace-env
	oc delete configmaps marketplace-db
	oc delete configmaps marketplace-app
	oc delete configmaps marketplace-messaging
	oc delete secret marketplace-secret
	oc delete secret marketplace-db

oc-delete-project:
	oc delete project marketplace

oc-delete-marketplace: oc-delete-marketplace-data oc-delete-project

oc-server-migrate: oc-forward-ports
	sleep 3
	DJANGO_READ_DOT_ENV_FILE=True $(PYTHON) $(PYDIR)/manage.py migrate
	make oc-stop-forwarding-ports

# internal command used by server-migrate & serve with oc
oc-stop-forwarding-ports:
	kill -HUP $$(ps -eo pid,command | grep "oc port-forward" | grep -v grep | awk '{print $$1}')

# internal command used by server-migrate & serve with oc
oc-forward-ports:
	-make oc-stop-forwarding-ports 2>/dev/null
	oc port-forward $$(oc get pods -o jsonpath='{.items[*].metadata.name}' -l name=marketplace-db) 15432:5432 >/dev/null 2>&1 &

serve-with-oc: oc-forward-ports
	sleep 3
	DJANGO_READ_DOT_ENV_FILE=True $(PYTHON) $(PYDIR)/manage.py runserver
	make oc-stop-forwarding-ports


oc-create-secret: OC_OBJECT = 'secret -l app=$(NAME)'
oc-create-secret: OC_PARAMETER_FILE = secret.env
oc-create-secret: OC_TEMPLATE_FILE = secret.yaml
oc-create-secret: OC_PARAMS = OC_OBJECT=$(OC_OBJECT) OC_PARAMETER_FILE=$(OC_PARAMETER_FILE) OC_TEMPLATE_FILE=$(OC_TEMPLATE_FILE) NAMESPACE=$(NAMESPACE)
oc-create-secret:
	$(OC_PARAMS) $(MAKE) __oc-apply-object
	$(OC_PARAMS) $(MAKE) __oc-create-object

##################################
### Internal openshift targets ###
##################################

__oc-create-project:
	@if [[ ! $$(oc get -o name project/$(NAMESPACE) 2>/dev/null) ]]; then \
		oc new-project $(NAMESPACE) ;\
	fi

# if object doesn't already exist,
# create it from the provided template and parameters
__oc-create-object: __oc-create-project
	@if [[ $$(oc get -o name $(OC_OBJECT) 2>&1) == '' ]] || \
	[[ $$(oc get -o name $(OC_OBJECT) 2>&1 | grep 'not found') ]]; then \
		if [ -f $(OC_PARAM_DIR)/$(OC_PARAMETER_FILE) ]; then \
			oc process -f $(OC_TEMPLATE_DIR)/$(OC_TEMPLATE_FILE) \
				--param-file=$(OC_PARAM_DIR)/$(OC_PARAMETER_FILE) \
			| oc create --save-config=True -n $(NAMESPACE) -f - 2>&1 | grep -v "already exists" || /usr/bin/true ;\
		else \
			oc process -f $(OC_TEMPLATE_DIR)/$(OC_TEMPLATE_FILE) \
				$(foreach PARAM, $(OC_PARAMETERS), -p $(PARAM)) \
			| oc create --save-config=True -n $(NAMESPACE) -f - 2>&1 | grep -v "already exists" || /usr/bin/true ;\
		fi ;\
	fi

 __oc-apply-object: __oc-create-project
	@if [[ $$(oc get -o name $(OC_OBJECT) 2>&1) != '' ]] || \
	[[ $$(oc get -o name $(OC_OBJECT) 2>&1 | grep -v 'not found') ]]; then \
		echo "WARNING: Resources matching 'oc get $(OC_OBJECT)' exists. Updating template. Skipping object creation." ;\
		if [ -f $(OC_PARAM_DIR)/$(OC_PARAMETER_FILE) ]; then \
			oc process -f $(OC_TEMPLATE_DIR)/$(OC_TEMPLATE_FILE) \
				--param-file=$(OC_PARAM_DIR)/$(OC_PARAMETER_FILE) \
			| oc apply -f - ;\
		else \
			oc process -f $(OC_TEMPLATE_DIR)/$(OC_TEMPLATE_FILE) \
				$(foreach PARAM, $(OC_PARAMETERS), -p $(PARAM)) \
			| oc apply -f - ;\
		fi ;\
	fi

#
# Phony targets
#
.PHONY: docs __oc-create-object __oc-create-project __oc-apply-object
