# ssh host of your DGX Spark, and the directory there
SPARK ?= spark
DEST  ?= gamespark

.PHONY: test deploy matrix

test:            ## offline checks (syntax, self-tests)
	@bash tests/run.sh

deploy:          ## copy the working tree to the Spark (SPARK=ssh-host DEST=dir)
	rsync -a --delete --exclude .git ./ $(SPARK):$(DEST)/
	ssh $(SPARK) 'cd $(DEST) && bash tests/run.sh'

matrix: deploy   ## regression gate on the Spark: every tuned game at its profile vs the recorded mean
	ssh $(SPARK) '$(DEST)/bench/matrix.sh'
