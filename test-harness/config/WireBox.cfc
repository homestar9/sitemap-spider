component extends="coldbox.system.ioc.config.Binder"{

	/**
	 * configure
	 *
	 * Defines the test harness WireBox settings.
	 */
	function configure(){

		// Register WireBox in application scope.
		wireBox = {
			scopeRegistration = {
				enabled = true,
				scope   = "application",
				key		= "wireBox"
			},

			customDSL = {
			},

			customScopes = {
			},

			scanLocations = [],
			stopRecursions = [],
			parentInjector = "",
			listeners = [
			]
		};
	}

}
