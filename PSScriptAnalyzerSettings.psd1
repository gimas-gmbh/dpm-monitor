@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive tools (inventory, configuration UI) talk to the admin on purpose.
        'PSAvoidUsingWriteHost'
    )
}
