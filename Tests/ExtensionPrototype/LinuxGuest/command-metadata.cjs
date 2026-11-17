function makeUpdateCommandMetadata(update) {
  return async function updateCommandMetadata(metadata) {
    if (metadata === null || typeof metadata !== "object" || Array.isArray(metadata)) {
      throw new TypeError("Expected command metadata");
    }
    const { subtitle } = metadata;
    if (subtitle === undefined) return;
    if (subtitle !== null && (typeof subtitle !== "string" || Buffer.byteLength(subtitle) > 1024 || /\p{Cc}/u.test(subtitle))) {
      throw new TypeError("Invalid command subtitle");
    }
    await update(subtitle);
  };
}

module.exports = { makeUpdateCommandMetadata };
