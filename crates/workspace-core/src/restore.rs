use crate::SessionTransport;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreRecipe {
    pub launch_command: String,
}

pub fn build_restore_recipe(
    transport: SessionTransport,
    target_label: &str,
    shell: &str,
    cwd: Option<&str>,
) -> RestoreRecipe {
    let shell_command = match cwd {
        Some(cwd) => format!("cd {} && exec {} -l", shell_quote(cwd), shell_quote(shell)),
        None => format!("exec {} -l", shell_quote(shell)),
    };

    let launch_command = match transport {
        SessionTransport::Local => shell_command,
        SessionTransport::Ssh => format!(
            "ssh {target_label} -- '{}'",
            escape_for_single_quotes(&shell_command)
        ),
    };

    RestoreRecipe { launch_command }
}

fn shell_quote(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | ':'))
    {
        value.to_owned()
    } else {
        format!("'{}'", escape_for_single_quotes(value))
    }
}

fn escape_for_single_quotes(value: &str) -> String {
    value.replace('\'', "'\"'\"'")
}
