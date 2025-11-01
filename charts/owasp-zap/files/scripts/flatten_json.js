const fs = require('fs');

/**
 *
 * @param filename {string}
 * @return {any}
 */
function readJSONFile(filename) {
    return JSON.parse(fs.readFileSync(filename, 'utf8'));
}

/**
 *
 * @param filename {string}
 * @param data {string}
 * @return void
 */
function writeFile(filename, data) {
    fs.writeFileSync(filename, data, 'utf8');
}

/**
 *
 * @param obj {Record<string, any>}
 * @return {Record<string, any>}
 */
function clone(obj) {
    return JSON.parse(JSON.stringify(obj));
}

/**
 *
 * @param obj {Record<string, any>}
 * @param depth {number}
 * @return {Record<string, any>[]}
 */
function multiply(obj, depth = 1) {
    if (depth === 0) return [obj];

    /**
     * @type {Record<string, any>[]}
     */
    const results = [];
    const entries = Object.entries(obj);
    const arrayEntries = entries.filter(([, value]) => Array.isArray(value))

    if (arrayEntries.length > 0) {
        arrayEntries.forEach(([key, value]) => {
            for (const valueElement of value) {
                const newObj = clone({...obj, [key]: valueElement});
                const subObj = multiply(newObj, depth);
                results.push(...subObj);
            }
        });
    } else {
        const objEntries = entries.filter(([, value]) => typeof value === 'object');

        if (objEntries.length > 0) {
            objEntries.forEach(([key, value]) => {
                const subValue = multiply(value, depth - 1);
                subValue.forEach((valueElement) => {
                    const newObj = clone({...obj, [key]: valueElement});
                    results.push(newObj);
                });
            });
        } else {
            results.push(obj)
        }
    }
    return results;
}

/**
 *
 * @param inputFile {string}
 * @param outputFile {string}
 * @param maxDepth {number}
 */
function main(inputFile, outputFile, maxDepth) {
    const jsonData = readJSONFile(inputFile);
    const processedData = multiply(jsonData, maxDepth);
    const strJsonL = processedData.map(i => JSON.stringify(i)).join('\n')
    writeFile(outputFile, strJsonL);
}

/**
 * @type {string[]}
 */
const args = process.argv.slice(2);
if (args.length !== 3) {
    console.error('Usage: node flatter_json <input_file> <output_file> <max_depth>');
    process.exit(1);
}
const [inputFile, outputFile, maxDepth] = args;
main(inputFile, outputFile, parseInt(maxDepth, 10));
