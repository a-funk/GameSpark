SPARK ?= spark          # ssh host of your DGX Spark
DEST  ?= gamespark

.PHONY: test deploy

test:            ## offline checks (syntax, self-tests)
	@bash tests/run.sh

deploy:          ## copy the working tree to the Spark (SPARK=ssh-host DEST=dir)
	rsync -a --delete --exclude .git ./ $(SPARK):$(DEST)/
	ssh $(SPARK) 'cd $(DEST) && bash tests/run.sh'
