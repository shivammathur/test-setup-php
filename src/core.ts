import {EOL} from 'os';

/**
 * Commands
 *
 * Command Format:
 *   ::name key=value,key=value::message
 *
 * @see https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions
 */

interface CommandProperties {
  [key: string]: string;
}

/**
 * Sanitizes the message for use in a workflow command.
 * @param message
 */
function toCommandValue(message: string | Error): string {
  if (message instanceof Error) {
    return message.toString();
  }
  return message;
}

/**
 * Escapes data for safe use in workflow command messages.
 * @param s
 */
function escapeData(s: string | Error): string {
  return toCommandValue(s)
    .replace(/%/g, '%25')
    .replace(/\r/g, '%0D')
    .replace(/\n/g, '%0A');
}

/**
 * Escapes property values for safe use in workflow command properties.
 * @param s
 */
function escapeProperty(s: string): string {
  return s
    .replace(/%/g, '%25')
    .replace(/\r/g, '%0D')
    .replace(/\n/g, '%0A')
    .replace(/:/g, '%3A')
    .replace(/,/g, '%2C');
}

/**
 * Issues a command to the GitHub Actions runner.
 *
 * @param command - The command name to issue
 * @param properties - Additional properties for the command (key-value pairs)
 * @param message - The message to include with the command
 */
export function issueCommand(
  command: string,
  properties: CommandProperties,
  message: string | Error
): void {
  let cmdStr = `::${command}`;

  if (properties && Object.keys(properties).length > 0) {
    cmdStr += ' ';
    const props = Object.entries(properties)
      .filter(([, val]) => val)
      .map(([key, val]) => `${key}=${escapeProperty(val)}`)
      .join(',');
    cmdStr += props;
  }

  cmdStr += `::${escapeData(message)}`;
  process.stdout.write(cmdStr + EOL);
}

/**
 * Adds an error issue.
 * @param message - error issue message
 */
export function error(message: string | Error): void {
  issueCommand('error', {}, message);
}

/**
 * Sets the action status to failed.
 * When the action exits it will be with an exit code of 1.
 * @param message - add error issue message
 */
export function setFailed(message: string | Error): void {
  process.exitCode = 1;
  error(message);
}

/**
 * Gets the value of an input.
 * The value is trimmed.
 * Returns an empty string if the value is not defined.
 *
 * @param name - name of the input to get
 * @param required - whether the input is required
 * @returns string
 */
export function getInput(name: string, required = false): string {
  const val: string =
    process.env[`INPUT_${name.replace(/ /g, '_').toUpperCase()}`] || '';
  if (required && !val) {
    throw new Error(`Input required and not supplied: ${name}`);
  }
  return val.trim();
}
